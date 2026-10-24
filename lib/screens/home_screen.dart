import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/recognition_state.dart';
import '../services/native_tts_service.dart';
import '../utils/app_theme.dart' as palette;
import '../utils/strings.dart';
import '../widgets/audio_controls.dart';
import '../widgets/camera_preview.dart';
import '../widgets/connection_status_bar.dart';
import '../widgets/deep_info_card.dart';
import '../widgets/hazard_banner.dart';
import '../widgets/live_label_chip.dart';
import '../widgets/spectrum_card.dart';

/// Main screen — voice-first, bilingual, RTL-aware.
///
/// Two camera sources feed the same pipeline:
///   * Phone camera (works immediately, demo / lab use)
///   * ESP32-CAM glasses over BLE (the wearable build)
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _muted = false;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    // Auto-start phone camera so the app is usable out of the box.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final state = context.read<RecognitionState>();
      try {
        await state.startPhoneCamera();
      } catch (e) {
        debugPrint('phone camera autostart: $e');
      }
    });
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.camera,
    ].request();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RecognitionState>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('SpectruLenPor'),
            Text(
              S.t(context, S.appTagline),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w400,
                color: palette.AppColors.alabasterGrey,
              ),
            ),
          ],
        ),
        actions: [
          // Flashlight: glasses LED over BLE, or phone torch in phone mode.
          IconButton(
            tooltip: S.t(context, S.flashlight),
            icon: Icon(
              state.flashOn ? Icons.flashlight_on : Icons.flashlight_off,
              color: state.flashOn ? palette.AppColors.warning : null,
            ),
            onPressed: () => state.setFlashlight(!state.flashOn),
          ),
          // Language quick-toggle EN <-> AR.
          TextButton(
            onPressed: () async {
              final next = state.isArabic ? 'en' : 'ar';
              await state.setLocale(next);
              appLocale.value = Locale(next);
            },
            child: Text(
              state.isArabic ? 'EN' : 'ع',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w800),
            ),
          ),
          IconButton(
            tooltip: S.t(context, S.settings),
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            // Hazard alert (top, unmissable)
            if (state.hazardActive)
              HazardBanner(
                reason: state.hazardReason,
                onDismiss: state.clearHazard,
              ),

            // Source switch: phone camera <-> glasses
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: SegmentedButton<CameraSource>(
                segments: [
                  ButtonSegment(
                    value: CameraSource.phone,
                    label: Text(S.t(context, S.phoneCamera)),
                    icon: const Icon(Icons.smartphone, size: 17),
                  ),
                  ButtonSegment(
                    value: CameraSource.glasses,
                    label: Text(S.t(context, S.glassesCam)),
                    icon: const Icon(Icons.visibility, size: 17),
                  ),
                ],
                selected: {state.source},
                onSelectionChanged: (sel) =>
                    state.switchSource(sel.first),
                style: SegmentedButton.styleFrom(
                  selectedBackgroundColor: palette.AppColors.dustyLavender,
                  selectedForegroundColor: Colors.white,
                  backgroundColor: palette.AppColors.surfaceLight,
                  foregroundColor: palette.AppColors.inkSoft,
                  side: BorderSide(color: palette.AppColors.silver),
                ),
              ),
            ),

            // BLE status bar (only meaningful in glasses mode)
            if (state.source == CameraSource.glasses)
              ConnectionStatusBar(
                status: state.btStatus,
                onConnect: () async {
                  try {
                    await state.connectToGlasses();
                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text('$e')));
                  }
                },
                onDisconnect: state.disconnect,
              ),

            // Live preview
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: state.usingPhoneCamera
                  ? _PhonePreview(state: state)
                  : CameraPreviewWidget(
                      jpegBytes: state.lastFrame?.jpegBytes,
                      capturedAt: state.lastFrame?.capturedAt,
                      isLive: state.btStatus == BluetoothStatus.connected,
                    ),
            ),

            // Instant local label (specialized model / ML Kit)
            LiveLabelChip(
              label: state.lastLabel,
              source: state.visionSource,
            ),

            // Actions
            AudioControls(
              speaking: !_muted && state.liveSpeak,
              busy: state.upstreamStatus == UpstreamStatus.streaming,
              onDescribeNow: () async {
                if (_muted) {
                  setState(() => _muted = false);
                  state.liveSpeak = true;
                }
                await state.captureAndAnalyzeNow();
              },
              onToggleSpeak: () async {
                setState(() => _muted = !_muted);
                state.liveSpeak = !_muted;
                if (_muted) await NativeTtsService.instance.stop();
              },
            ),

            // Spectrum panel (UV/IR + state of matter + ONNX top-3)
            SpectrumCard(
              reading: state.lastReading,
              predictions: state.lastPredictions,
              state: state.matterState,
              hazardActive: state.hazardActive,
              hasTelemetry: state.lastReading != null,
            ),

            // AI analysis (presentation pass)
            DeepInfoCard(
              markdown: state.deepReasoningMarkdown,
              status: state.upstreamStatus,
            ),

            // Latency metric (transparency for the science fair!)
            if (state.upstreamMs > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '⏱ first audio token: ${state.upstreamMs} ms',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: palette.AppColors.inkSoft),
                ),
              ),

            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text(
                S.t(context, S.credits),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: palette.AppColors.silver, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Phone-camera live preview (native texture). Taps capture + analyze.
class _PhonePreview extends StatelessWidget {
  final RecognitionState state;
  const _PhonePreview({required this.state});

  @override
  Widget build(BuildContext context) {
    final ctrl = state.phoneCamera.controller;
    if (ctrl == null || !ctrl.value.isInitialized) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: AspectRatio(
          aspectRatio: 4 / 3,
          child: Container(
            color: palette.AppColors.inkDark,
            child: Center(
              child: Text(
                S.t(context, S.waitingFrame),
                textAlign: TextAlign.center,
                style: const TextStyle(color: palette.AppColors.silver),
              ),
            ),
          ),
        ),
      );
    }
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: CameraPreview(ctrl),
          ),
        ),
        if (state.flashOn)
          const Positioned(
            top: 10,
            left: 10,
            child: Icon(Icons.flashlight_on,
                color: palette.AppColors.warning, size: 22),
          ),
      ],
    );
  }
}
