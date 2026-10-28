import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../main.dart' show appLocale;
import '../models/bluetooth_status.dart';
import '../models/recognition_state.dart';
import '../utils/app_theme.dart' as palette;
import '../utils/app_typography.dart';
import '../widgets/bounding_box_overlay.dart';
import '../widgets/camera_preview.dart';
import '../widgets/connection_status_bar.dart';
import '../widgets/hazard_banner.dart';
import '../widgets/spectrum_card.dart';
import 'chat_screen.dart';
import 'history_screen.dart';

/// Main home screen:
///   * Full-viewport un-shrimped camera preview (`SizedBox.expand` + `FittedBox.cover`)
///   * Real-time local YOLO26-Nano interactive bounding boxes + target lock-on marker
///   * Strict user-gated dual JPEG capture (`cleanJpeg` + marked `withBoxesJpeg`) ONLY
///     when a bounding box is selected and the user taps Capture & Analyze
///   * BLE smart-glasses feed + UV/IR telemetry + hazard alerts + History/Docs access
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<RecognitionState>().checkCameraPermission();
    });
  }

  Future<void> _triggerCaptureAndOpenChat(RecognitionState state) async {
    if (state.selectedBox == null || state.isAnalyzingSelected) return;
    HapticFeedback.mediumImpact();
    final ok = await state.captureAndAnalyzeSelected();
    if (ok && mounted && state.chatSession != null) {
      await Navigator.push(context, _createSlideRoute(const ChatScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RecognitionState>();
    final loc = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: palette.AppColors.alabasterGrey,
      appBar: _buildAppBar(context, state, loc),
      body: Column(
        children: [
          _buildStatusBar(context, state, loc),
          if (state.hazardActive)
            HazardBanner(
              reason: state.hazardReason,
              onDismiss: state.clearHazard,
            ),
          _buildSourceToggle(context, state, loc),
          if (state.source == CameraSource.glasses)
            ConnectionStatusBar(
              status: state.btStatus,
              deviceName: state.bluetooth.deviceName,
              onConnect: state.connectToGlasses,
              onDisconnect: state.disconnect,
            ),
          Expanded(child: _buildCameraArea(state, loc)),
          _buildCaptureControlBar(context, state),
          if (state.source == CameraSource.glasses && state.lastReading != null)
            SpectrumCard(
              reading: state.lastReading,
              predictions: state.lastPredictions,
              state: state.matterState,
              hazardActive: state.hazardActive,
              hasTelemetry: true,
            ),
          _buildBottomBar(context, state, loc),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // APP BAR
  // ---------------------------------------------------------------------------
  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    RecognitionState state,
    AppLocalizations loc,
  ) {
    final isAr = Localizations.localeOf(context).languageCode.startsWith('ar');
    return AppBar(
      backgroundColor: palette.AppColors.dustyLavender,
      elevation: 0,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.visibility_rounded, color: Colors.white, size: 20),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              loc.appName,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.displayOf(
                context,
                color: Colors.white,
                fontSize: 18,
              ),
            ),
          ),
        ],
      ),
      actions: [
        _AnimatedIconButton(
          icon: Icons.history_edu_rounded,
          color: Colors.white,
          tooltip: isAr ? 'السجل والموسوعة العلمية' : 'History & Scientific Docs',
          onTap: () => Navigator.push(
            context,
            _createSlideRoute(const HistoryScreen()),
          ),
        ),
        if (state.chatSession != null)
          _AnimatedIconButton(
            icon: Icons.forum_outlined,
            color: Colors.white,
            tooltip: isAr ? 'فتح المحادثة' : 'Open chat',
            onTap: () => Navigator.push(
              context,
              _createSlideRoute(const ChatScreen()),
            ),
          ),
        _AnimatedIconButton(
          icon: state.flashOn
              ? Icons.flashlight_on_rounded
              : Icons.flashlight_off_rounded,
          color: state.flashOn ? palette.AppColors.warning : Colors.white70,
          tooltip: loc.flashlight,
          onTap: () => state.setFlashlight(!state.flashOn),
        ),
        _AnimatedIconButton(
          icon: state.cloudOnly
              ? Icons.cloud_done_rounded
              : Icons.cloud_queue_rounded,
          color: state.cloudOnly ? palette.AppColors.warning : Colors.white70,
          tooltip: state.cloudOnly
              ? 'Cloud-only models ON (YOLO local)'
              : 'Hybrid Cloud + Offline models',
          onTap: () => state.cloudOnly = !state.cloudOnly,
        ),
        TextButton(
          onPressed: () async {
            final next = isAr ? 'en' : 'ar';
            await state.setLocale(next);
            appLocale.value = Locale(next);
          },
          child: Text(
            isAr ? 'EN' : 'ع',
            style: AppTypography.bodyOf(
              context,
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        _AnimatedIconButton(
          icon: Icons.settings_outlined,
          color: Colors.white,
          tooltip: loc.settings,
          onTap: () => Navigator.pushNamed(context, '/settings'),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // STATUS BAR
  // ---------------------------------------------------------------------------
  Widget _buildStatusBar(
    BuildContext context,
    RecognitionState state,
    AppLocalizations loc,
  ) {
    final statusText = state.btStatus == BluetoothStatus.connected
        ? loc.connected
        : (state.usingPhoneCamera ? loc.phoneCamera : loc.glassesNotConnected);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      color: palette.AppColors.dustGrey,
      child: Row(
        children: [
          Icon(
            state.btStatus == BluetoothStatus.connected
                ? Icons.bluetooth_connected_rounded
                : Icons.sensors_rounded,
            size: 15,
            color: palette.AppColors.dustyLavender,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              statusText,
              style: AppTypography.bodyOf(context, fontSize: 12),
            ),
          ),
          if (state.cloudOnly)
            Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: palette.AppColors.dustyLavender,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'CLOUD+YOLO',
                style: GoogleFonts.spaceMono(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          if (state.lastGate != null)
            Text(
              '${state.lastGate!.reason} · ${state.lastGate!.brightness.toStringAsFixed(0)}',
              style: GoogleFonts.spaceMono(fontSize: 10),
            ),
          if (state.autoFlashOn) const _AutoFlashBadge(),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SOURCE TOGGLE
  // ---------------------------------------------------------------------------
  Widget _buildSourceToggle(
    BuildContext context,
    RecognitionState state,
    AppLocalizations loc,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
      child: Row(
        children: [
          Expanded(
            child: _segButton(
              context,
              Icons.smartphone_rounded,
              loc.phoneCamera,
              state.source == CameraSource.phone,
              () => state.switchSource(CameraSource.phone),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _segButton(
              context,
              Icons.visibility_rounded,
              loc.glassesCam,
              state.source == CameraSource.glasses,
              () => state.switchSource(CameraSource.glasses),
            ),
          ),
        ],
      ),
    );
  }

  Widget _segButton(
    BuildContext context,
    IconData icon,
    String label,
    bool active,
    VoidCallback onTap,
  ) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 10),
          decoration: BoxDecoration(
            color: active ? palette.AppColors.dustyLavender : Colors.white,
            border: Border.all(
              color: palette.AppColors.dustyLavender,
              width: 1,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: active ? Colors.white : palette.AppColors.dustyLavender,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: AppTypography.bodyOf(
                    context,
                    color:
                        active ? Colors.white : palette.AppColors.dustyLavender,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // CAMERA VIEWPORT — generous full-width/full-height un-shrimped preview
  // ---------------------------------------------------------------------------
  Widget _buildCameraArea(RecognitionState state, AppLocalizations loc) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox.expand(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            child: _resolveCameraState(state, loc),
          ),
        ),
      ),
    );
  }

  Widget _resolveCameraState(RecognitionState state, AppLocalizations loc) {
    if (state.source == CameraSource.glasses) {
      return _GlassesPreviewArea(
        key: const ValueKey('glasses_preview'),
        state: state,
      );
    }

    if (state.cameraPermission != PermissionStatus.granted) {
      return _PermissionCard(
        key: const ValueKey('permission_card'),
        state: state,
      );
    }

    final ctrl = state.phoneCamera.controller;
    if (ctrl == null || !ctrl.value.isInitialized) {
      return _LoadingState(
        key: const ValueKey('camera_loading'),
        message: state.isArabic ? 'جارٍ تشغيل الكاميرا…' : 'Starting camera…',
      );
    }

    return _CameraPreviewNative(
      key: const ValueKey('phone_preview'),
      state: state,
    );
  }

  // ---------------------------------------------------------------------------
  // STRICT USER-GATED CAPTURE & ANALYZE CONTROL BAR
  // ---------------------------------------------------------------------------
  Widget _buildCaptureControlBar(BuildContext context, RecognitionState state) {
    final isAr = Localizations.localeOf(context).languageCode.startsWith('ar');
    final sel = state.selectedBox;
    final canCapture = sel != null && !state.isAnalyzingSelected;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed:
                  canCapture ? () => _triggerCaptureAndOpenChat(state) : null,
              icon: Icon(
                sel != null
                    ? Icons.camera_enhance_rounded
                    : Icons.touch_app_rounded,
                size: 18,
              ),
              label: Text(
                state.isAnalyzingSelected
                    ? (isAr
                        ? 'جارٍ التقاط الإطارين والتحليل…'
                        : 'Capturing Clean + Marked Frames…')
                    : sel != null
                        ? (isAr
                            ? 'التقاط صورتين وتحليل "${sel.label}"'
                            : 'Capture 2 Frames & Analyze "${sel.label}"')
                        : (isAr
                            ? 'حدّد صندوقاً من الكاميرا لتفعيل الالتقاط'
                            : 'Select a YOLO Box on Camera to Capture'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: sel != null
                    ? palette.AppColors.dustyLavender
                    : palette.AppColors.silver,
                disabledBackgroundColor:
                    palette.AppColors.dustGrey.withOpacity(0.9),
                disabledForegroundColor: palette.AppColors.inkSoft,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          if (sel != null && !state.isAnalyzingSelected) ...[
            const SizedBox(width: 6),
            IconButton.outlined(
              tooltip: isAr ? 'إلغاء التحديد' : 'Clear selected target',
              onPressed: () => state.selectBox(null),
              icon: const Icon(Icons.deselect_rounded, size: 19),
            ),
          ] else if (state.chatSession != null && !state.isAnalyzingSelected) ...[
            const SizedBox(width: 6),
            IconButton.filledTonal(
              tooltip: isAr ? 'متابعة المحادثة' : 'Open active chat',
              onPressed: () => Navigator.push(
                context,
                _createSlideRoute(const ChatScreen()),
              ),
              icon: const Icon(Icons.forum_rounded, size: 19),
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // BOTTOM LIVE ANALYSIS SUMMARY BAR
  // ---------------------------------------------------------------------------
  Widget _buildBottomBar(
    BuildContext context,
    RecognitionState state,
    AppLocalizations loc,
  ) {
    final busy = state.isAnalyzingSelected ||
        state.upstreamStatus == UpstreamStatus.waiting ||
        state.upstreamStatus == UpstreamStatus.streaming;
    final isAr = Localizations.localeOf(context).languageCode.startsWith('ar');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: palette.AppColors.dustyLavender.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.science_rounded,
                size: 16,
                color: palette.AppColors.dustyLavender,
              ),
              const SizedBox(width: 5),
              Text(
                loc.deepReasoning,
                style: AppTypography.displayOf(
                  context,
                  color: palette.AppColors.dustyLavender,
                  fontSize: 14,
                ),
              ),
              const Spacer(),
              if (busy)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: palette.AppColors.dustyLavender,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 3),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Text(
              state.lastLabel ??
                  (isAr ? 'في انتظار التحليل…' : 'Waiting for analysis…'),
              key: ValueKey(state.lastLabel),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.paragraphOf(context, fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }

  Route<void> _createSlideRoute(Widget page) {
    return PageRouteBuilder<void>(
      pageBuilder: (context, animation, secondary) => page,
      transitionsBuilder: (context, animation, secondary, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          ),
          child: child,
        );
      },
    );
  }
}

// ===========================================================================
// GLASSES PREVIEW AREA — Full-bleed BLE JPEG stream + YOLO overlay
// ===========================================================================
class _GlassesPreviewArea extends StatelessWidget {
  final RecognitionState state;
  const _GlassesPreviewArea({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final frame = state.lastFrame;
    final aspect = (frame != null && frame.width > 0 && frame.height > 0)
        ? frame.width / frame.height
        : (320.0 / 240.0);

    return Container(
      color: palette.AppColors.inkDark,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreviewWidget(
            frame: frame,
            status: state.btStatus,
            liveLabel: null,
          ),
          if (state.currentBoxes.isNotEmpty || state.selectedBox != null)
            BoundingBoxOverlay(
              boxes: state.currentBoxes,
              selected: state.selectedBox,
              sourceAspectRatio: aspect,
              onSelect: (b) {
                HapticFeedback.selectionClick();
                state.selectBox(b);
              },
            ),
          if (state.currentBoxes.isNotEmpty)
            Positioned(
              top: 44,
              left: 10,
              child: _DetectionCountBadge(count: state.currentBoxes.length),
            ),
          if (state.selectedBox == null && state.currentBoxes.isNotEmpty)
            Positioned(
              bottom: 12,
              left: 0,
              right: 0,
              child: Center(
                child: _HintChip(
                  text: state.isArabic
                      ? 'اضغط على صندوق لتحديده ثم اضغط التقاط'
                      : 'Tap a box to mark target, then press Capture',
                ),
              ),
            ),
          if (state.isAnalyzingSelected)
            Positioned.fill(
              child: Container(
                color: Colors.black54,
                child: Center(child: _AnalyzingOverlay(state: state)),
              ),
            ),
        ],
      ),
    );
  }
}

// ===========================================================================
// PERMISSION CARD
// ===========================================================================
class _PermissionCard extends StatelessWidget {
  final RecognitionState state;
  const _PermissionCard({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode.startsWith('ar');
    return Container(
      color: palette.AppColors.inkDark,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: palette.AppColors.dustyLavender.withOpacity(0.18),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.camera_alt_outlined,
                  size: 38,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                isAr ? 'يلزم إذن الكاميرا' : 'Camera Access Required',
                style: AppTypography.displayOf(
                  context,
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                isAr
                    ? 'يحتاج التطبيق إلى الكاميرا لرصد الكائنات عبر YOLO26-Nano محلياً وتحليلها علمياً.'
                    : 'SpectruLenPor uses the camera for real-time local YOLO26-Nano detection and grounded scientific analysis.',
                textAlign: TextAlign.center,
                style: AppTypography.bodyOf(
                  context,
                  color: Colors.white60,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => state.requestCameraPermission(),
                  icon: const Icon(Icons.lock_open_rounded, size: 18),
                  label: Text(
                    isAr ? 'السماح بالوصول' : 'Grant Access',
                    style: AppTypography.bodyOf(
                      context,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: palette.AppColors.dustyMauve,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              if (state.cameraPermission ==
                  PermissionStatus.permanentlyDenied) ...[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => openAppSettings(),
                  child: Text(
                    isAr
                        ? 'تم الرفض — افتح الإعدادات'
                        : 'Permanently denied — Open Settings',
                    style: AppTypography.bodyOf(
                      context,
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// LOADING STATE
// ===========================================================================
class _LoadingState extends StatelessWidget {
  final String message;
  const _LoadingState({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: palette.AppColors.inkDark,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: palette.AppColors.dustyLavender,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              style: AppTypography.bodyOf(
                context,
                color: Colors.white70,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// NATIVE PHONE CAMERA PREVIEW — Full-viewport edge-to-edge BoxFit.cover
// ===========================================================================
class _CameraPreviewNative extends StatelessWidget {
  final RecognitionState state;
  const _CameraPreviewNative({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final ctrl = state.phoneCamera.controller;
    if (ctrl == null || !ctrl.value.isInitialized) {
      return _LoadingState(
        message:
            state.isArabic ? 'جارٍ تهيئة الكاميرا…' : 'Initializing camera…',
      );
    }

    // Sensor previewSize is reported in landscape (width > height); in locked
    // portrait orientation, the upright preview dimensions are (height, width).
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final ps = ctrl.value.previewSize;
    final double previewW;
    final double previewH;
    if (ps != null && ps.width > 0 && ps.height > 0) {
      previewW = isLandscape ? ps.width : ps.height;
      previewH = isLandscape ? ps.height : ps.width;
    } else {
      final fallback =
          state.phoneCamera.previewLogicalSize ?? const Size(720, 1280);
      previewW = fallback.width;
      previewH = fallback.height;
    }

    final coverAspect = previewW / previewH;

    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Edge-to-edge full-viewport native preview (never shrimped/letterboxed)
          ClipRect(
            child: SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.cover,
                alignment: Alignment.center,
                child: SizedBox(
                  width: previewW,
                  height: previewH,
                  child: CameraPreview(ctrl),
                ),
              ),
            ),
          ),

          // Interactive YOLO26-Nano bounding boxes projected with identical cover math
          if (state.currentBoxes.isNotEmpty || state.selectedBox != null)
            BoundingBoxOverlay(
              boxes: state.currentBoxes,
              selected: state.selectedBox,
              sourceAspectRatio: coverAspect,
              onSelect: (b) {
                HapticFeedback.selectionClick();
                state.selectBox(b);
              },
            ),

          if (state.phoneCamera.isStreaming)
            const Positioned(
              top: 10,
              right: 10,
              child: _LiveBadge(),
            ),

          Positioned(
            top: 10,
            left: 10,
            child: _DetectionCountBadge(
              count: state.currentBoxes.length,
              yoloReady: state.yolo.isReady,
            ),
          ),

          if (state.selectedBox == null && state.currentBoxes.isNotEmpty)
            Positioned(
              bottom: 12,
              left: 12,
              right: 12,
              child: Center(
                child: _HintChip(
                  text: state.isArabic
                      ? 'اضغط على أي صندوق لوضع علامة الهدف ثم اضغط التقاط'
                      : 'Tap any box to lock target marker, then press Capture',
                ),
              ),
            ),

          if (state.isAnalyzingSelected)
            Positioned.fill(
              child: Container(
                color: Colors.black54,
                child: Center(
                  child: _AnalyzingOverlay(state: state),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ===========================================================================
// BADGES & CHIPS
// ===========================================================================
class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: palette.AppColors.danger.withOpacity(0.9),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.fiber_manual_record_rounded,
              size: 8, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            'LIVE',
            style: GoogleFonts.spaceMono(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

class _DetectionCountBadge extends StatelessWidget {
  final int count;
  final bool yoloReady;
  const _DetectionCountBadge({
    required this.count,
    this.yoloReady = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: palette.AppColors.inkDark.withOpacity(0.8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: palette.AppColors.dustyMauve.withOpacity(0.8),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            yoloReady ? Icons.radar_rounded : Icons.downloading_rounded,
            size: 13,
            color: Colors.white,
          ),
          const SizedBox(width: 5),
          Text(
            yoloReady ? 'YOLO26n · $count' : 'YOLO26n staging…',
            style: GoogleFonts.rubik(
              color: Colors.white,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _HintChip extends StatelessWidget {
  final String text;
  const _HintChip({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: palette.AppColors.inkDark.withOpacity(0.76),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.touch_app_rounded, size: 14, color: Colors.white),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.bodyOf(
                context,
                color: Colors.white,
                fontSize: 11.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AutoFlashBadge extends StatelessWidget {
  const _AutoFlashBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: palette.AppColors.dustyMauve,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'AUTO',
        style: GoogleFonts.spaceMono(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AnalyzingOverlay extends StatelessWidget {
  final RecognitionState state;
  const _AnalyzingOverlay({required this.state});

  @override
  Widget build(BuildContext context) {
    final msg = state.analyzingStage.isNotEmpty
        ? state.analyzingStage
        : (state.isArabic
            ? 'جارٍ التحليل عبر موندريم…'
            : 'Analyzing with Moondream AI…');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 46,
            height: 46,
            child: CircularProgressIndicator(
              strokeWidth: 3.5,
              color: palette.AppColors.dustyMauve,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            msg,
            textAlign: TextAlign.center,
            style: AppTypography.bodyOf(
              context,
              color: Colors.white,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _AnimatedIconButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  const _AnimatedIconButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_AnimatedIconButton> createState() => _AnimatedIconButtonState();
}

class _AnimatedIconButtonState extends State<_AnimatedIconButton> {
  double _scale = 1.0;

  Future<void> _handlePressed() async {
    HapticFeedback.selectionClick();
    setState(() => _scale = 0.85);
    widget.onTap();
    await Future<void>.delayed(const Duration(milliseconds: 110));
    if (mounted) {
      setState(() => _scale = 1.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _scale,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOutBack,
      child: IconButton(
        icon: Icon(widget.icon, color: widget.color, size: 21),
        tooltip: widget.tooltip,
        onPressed: _handlePressed,
      ),
    );
  }
}
