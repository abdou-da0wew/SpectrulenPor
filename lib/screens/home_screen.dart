import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/recognition_state.dart';
import '../services/native_tts_service.dart';
import '../utils/app_theme.dart' as palette;
import '../widgets/audio_controls.dart';
import '../widgets/camera_preview.dart';
import '../widgets/connection_status_bar.dart';
import '../widgets/deep_info_card.dart';
import '../widgets/live_label_chip.dart';

/// Main screen: BLE connection header, live camera frame preview,
/// instant local label, and the streamed deep-reasoning card.
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
    final frame = state.lastFrame;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                gradient: palette.AppColors.headerGradient,
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.visibility, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('SpectrulenPor'),
                Text('Smart scientific glasses',
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w400,
                        color: palette.AppColors.alabasterGrey)),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            // 1) BLE status bar
            ConnectionStatusBar(
              status: state.btStatus,
              onConnect: () async {
                try {
                  await state.connectToGlasses();
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('$e')),
                  );
                }
              },
              onDisconnect: state.disconnect,
            ),

            // 2) Live camera preview (frame from ESP32-CAM)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: CameraPreviewWidget(
                jpegBytes: frame?.jpegBytes,
                capturedAt: frame?.capturedAt,
                isLive: state.btStatus == BluetoothStatus.connected,
              ),
            ),

            // 3) Instant on-device label
            LiveLabelChip(
              label: state.lastLabel,
              source: state.visionSource,
            ),

            // 4) Action buttons
            AudioControls(
              speaking: !_muted && state.liveSpeak,
              busy: state.upstreamStatus == UpstreamStatus.streaming,
              onDescribeNow: () async {
                if (_muted) {
                  setState(() => _muted = false);
                  await NativeTtsService.instance.speak('Sound on.');
                }
                await state.captureAndAnalyzeNow();
              },
              onToggleSpeak: () async {
                setState(() => _muted = !_muted);
                state.liveSpeak = !_muted;
                if (_muted) await NativeTtsService.instance.stop();
              },
            ),

            // 5) Deep reasoning card (streamed from OpenRouter)
            DeepInfoCard(
              markdown: state.deepReasoningMarkdown,
              status: state.upstreamStatus,
            ),

            // 6) Footer hint
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text(
                'SpectrulenPor · Supervised by Dr. Khaled Sibakat · Elaf Al-Tai · CS 2025/2026',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: palette.AppColors.silver),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
