import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/bounding_box.dart';
import '../models/bluetooth_status.dart';
import '../models/recognition_state.dart';
import '../utils/app_theme.dart' as palette;
import '../widgets/bounding_box_overlay.dart';
import 'chat_screen.dart';

/// Main home screen — full UX with permission flow, native camera preview,
/// YOLO bounding box overlay, loading states, microinteractions, and
/// animated transitions.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  late final AnimationController _fabController;
  late final Animation<double> _fabScale;

  @override
  void initState() {
    super.initState();
    _fabController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fabScale = CurvedAnimation(parent: _fabController, curve: Curves.elasticOut);
  }

  @override
  void dispose() {
    _fabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RecognitionState>();
    final loc = AppLocalizations.of(context);

    // Animate FAB when selectedBox changes
    if (state.selectedBox != null && state.chatSession == null) {
      _fabController.forward();
    } else {
      _fabController.reverse();
    }

    return Scaffold(
      backgroundColor: palette.AppColors.alabasterGrey,
      appBar: _buildAppBar(state, loc),
      body: Column(
        children: [
          _buildStatusBar(state),
          _buildSourceToggle(state),
          Expanded(child: _buildCameraArea(state, loc)),
          _buildBottomBar(state),
        ],
      ),
      floatingActionButton: _buildFab(context, state),
    );
  }

  // ---------------------------------------------------------------------------
  // APP BAR
  // ---------------------------------------------------------------------------
  PreferredSizeWidget _buildAppBar(RecognitionState state, AppLocalizations loc) {
    return AppBar(
      backgroundColor: palette.AppColors.dustyLavender,
      elevation: 0,
      title: Row(
        children: [
          Icon(Icons.visibility, color: Colors.white, size: 20),
          const SizedBox(width: 6),
          Text('SpectruLenPor',
              style: GoogleFonts.jaro(color: Colors.white, fontSize: 18)),
        ],
      ),
      actions: [
        // Flashlight toggle with animation
        _AnimatedIconButton(
          icon: state.flashOn ? Icons.flashlight_on : Icons.flashlight_off,
          color: state.flashOn ? palette.AppColors.warning : Colors.white70,
          tooltip: 'Flashlight',
          onTap: () => state.setFlashlight(!state.flashOn),
        ),
        // Cloud-only toggle
        _AnimatedIconButton(
          icon: state.cloudOnly ? Icons.cloud_off : Icons.cloud,
          color: state.cloudOnly ? palette.AppColors.warning : Colors.white70,
          tooltip: state.cloudOnly ? 'Cloud-only ON' : 'Cloud-only OFF',
          onTap: () => state.cloudOnly = !state.cloudOnly,
        ),
        // Language toggle
        TextButton(
          onPressed: () async => state.setLocale(state.isArabic ? 'en' : 'ar'),
          child: Text(
            state.isArabic ? 'EN' : 'ع',
            style: GoogleFonts.rubik(color: Colors.white, fontWeight: FontWeight.w700),
          ),
        ),
        // Settings
        _AnimatedIconButton(
          icon: Icons.settings_outlined,
          color: Colors.white,
          tooltip: 'Settings',
          onTap: () => Navigator.pushNamed(context, '/settings'),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // STATUS BAR
  // ---------------------------------------------------------------------------
  Widget _buildStatusBar(RecognitionState state) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: palette.AppColors.dustGrey,
      child: Row(
        children: [
          Icon(
            state.btStatus == BluetoothStatus.connected
                ? Icons.bluetooth_connected
                : Icons.bluetooth_disabled,
            size: 16,
            color: palette.AppColors.dustyLavender,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              state.btStatus == BluetoothStatus.connected
                  ? 'Glasses connected'
                  : 'Phone camera mode',
              style: GoogleFonts.rubik(fontSize: 12),
            ),
          ),
          if (state.lastGate != null)
            Text(
              '${state.lastGate!.reason} · ${state.lastGate!.brightness.toStringAsFixed(0)}',
              style: GoogleFonts.spaceMono(fontSize: 10),
            ),
          if (state.autoFlashOn) _AutoFlashBadge(),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SOURCE TOGGLE
  // ---------------------------------------------------------------------------
  Widget _buildSourceToggle(RecognitionState state) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(child: _segButton('Phone camera',
              state.source == CameraSource.phone,
              () => state.switchSource(CameraSource.phone))),
          Expanded(child: _segButton('Glasses',
              state.source == CameraSource.glasses,
              () => state.switchSource(CameraSource.glasses))),
        ],
      ),
    );
  }

  Widget _segButton(String label, bool active, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active ? palette.AppColors.dustyLavender : Colors.white,
            border: Border.all(color: palette.AppColors.dustyLavender, width: 1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: GoogleFonts.rubik(
              color: active ? Colors.white : palette.AppColors.dustyLavender,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // CAMERA AREA — permission flow + native preview + overlay + loading
  // ---------------------------------------------------------------------------
  Widget _buildCameraArea(RecognitionState state, AppLocalizations loc) {
    return Expanded(
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          child: _resolveCameraState(state, loc),
        ),
      ),
    );
  }

  Widget _resolveCameraState(RecognitionState state, AppLocalizations loc) {
    // 1. Permission not granted → show permission request card
    if (state.cameraPermission != PermissionStatus.granted) {
      return _PermissionCard(state: state);
    }
    // 2. Camera controller not initialized → loading shimmer
    final ctrl = state.phoneCamera.controller;
    if (ctrl == null || !ctrl.value.isInitialized) {
      return _LoadingState(message: 'Starting camera…');
    }
    // 3. Camera ready → native CameraPreview + overlay
    return _CameraPreviewNative(state: state);
  }

  // ---------------------------------------------------------------------------
  // BOTTOM BAR
  // ---------------------------------------------------------------------------
  Widget _buildBottomBar(RecognitionState state) {
    return Container(
      padding: const EdgeInsets.all(12),
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
              Icon(Icons.science, size: 16, color: palette.AppColors.dustyLavender),
              const SizedBox(width: 4),
              Text('Live analysis',
                  style: GoogleFonts.jaro(
                      color: palette.AppColors.dustyLavender, fontSize: 14)),
              const Spacer(),
              if (state.upstreamStatus != UpstreamStatus.idle)
                SizedBox(
                  width: 12, height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2,
                      color: palette.AppColors.dustyLavender),
                ),
            ],
          ),
          const SizedBox(height: 4),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Text(
              state.lastLabel ??
                  (state.isArabic ? 'في انتظار التحليل…' : 'Waiting for analysis…'),
              key: ValueKey(state.lastLabel),
              style: GoogleFonts.spaceMono(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // FAB — animated entrance when a box is selected
  // ---------------------------------------------------------------------------
  Widget? _buildFab(BuildContext context, RecognitionState state) {
    if (state.chatSession != null) {
      return FloatingActionButton.extended(
        onPressed: () => Navigator.push(context,
            _createSlideRoute(const ChatScreen())),
        backgroundColor: palette.AppColors.dustyLavender,
        icon: const Icon(Icons.chat, color: Colors.white),
        label: Text('Open chat',
            style: GoogleFonts.rubik(color: Colors.white)),
      );
    }
    if (state.selectedBox == null) return null;
    return ScaleTransition(
      scale: _fabScale,
      child: FloatingActionButton.extended(
        onPressed: () {
          HapticFeedback.mediumImpact();
          state.captureAndAnalyzeSelected();
        },
        backgroundColor: palette.AppColors.dustyMauve,
        icon: const Icon(Icons.science, color: Colors.white),
        label: Text('Analyze ${state.selectedBox!.label}',
            style: GoogleFonts.rubik(color: Colors.white)),
      ),
    );
  }

  Route _createSlideRoute(Widget page) {
    return PageRouteBuilder(
      pageBuilder: (context, animation, secondary) => page,
      transitionsBuilder: (context, animation, secondary, child) {
        return SlideTransition(
          position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
              .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: child,
        );
      },
    );
  }
}

// ===========================================================================
// PERMISSION CARD — shown when camera permission isn't granted
// ===========================================================================
class _PermissionCard extends StatelessWidget {
  final RecognitionState state;
  const _PermissionCard({required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: palette.AppColors.inkDark,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Animated camera icon
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.8, end: 1.0),
                duration: const Duration(milliseconds: 800),
                curve: Curves.elasticOut,
                builder: (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
                child: Container(
                  width: 80, height: 80,
                  decoration: BoxDecoration(
                    color: palette.AppColors.dustyLavender.withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.camera_alt_outlined,
                      size: 40, color: Colors.white70),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                state.isArabic
                    ? 'يلزم إذن الكاميرا'
                    : 'Camera Access Required',
                style: GoogleFonts.jaro(
                    color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                state.isArabic
                    ? 'يحتاج التطبيق إلى الكاميرا لاكتشاف الكائنات وتحليلها'
                    : 'SpectruLenPor needs the camera to detect objects and analyze them with YOLO26-Nano + Moondream AI.',
                textAlign: TextAlign.center,
                style: GoogleFonts.rubik(color: Colors.white60, fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 24),
              // Grant Access button
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => state.requestCameraPermission(),
                  icon: const Icon(Icons.lock_open, size: 18),
                  label: Text(
                    state.isArabic ? 'السماح بالوصول' : 'Grant Access',
                    style: GoogleFonts.rubik(fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: palette.AppColors.dustyMauve,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (state.cameraPermission == PermissionStatus.permanentlyDenied)
                TextButton(
                  onPressed: () => openAppSettings(),
                  child: Text(
                    state.isArabic
                        ? 'تم الرفض — افتح الإعدادات'
                        : 'Permanently denied — Open Settings',
                    style: GoogleFonts.rubik(color: Colors.white54, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// LOADING STATE — shimmer + spinner while camera initializes
// ===========================================================================
class _LoadingState extends StatelessWidget {
  final String message;
  const _LoadingState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: palette.AppColors.inkDark,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 32, height: 32,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: palette.AppColors.dustyLavender,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              style: GoogleFonts.rubik(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// NATIVE CAMERA PREVIEW — uses CameraController directly (zero latency)
// ===========================================================================
class _CameraPreviewNative extends StatelessWidget {
  final RecognitionState state;
  const _CameraPreviewNative({required this.state});

  @override
  Widget build(BuildContext context) {
    final ctrl = state.phoneCamera.controller;
    if (ctrl == null || !ctrl.value.isInitialized) {
      return _LoadingState(message: 'Initializing camera…');
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Native camera texture — zero latency
        ClipRect(
          child: OverflowBox(
            alignment: Alignment.center,
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: ctrl.value.previewSize?.height ?? 640,
                height: ctrl.value.previewSize?.width ?? 480,
                child: CameraPreview(ctrl),
              ),
            ),
          ),
        ),
        // Bounding box overlay
        if (state.currentBoxes.isNotEmpty)
          BoundingBoxOverlay(
            boxes: state.currentBoxes,
            selectedBox: state.selectedBox,
            onTapBox: (b) {
              HapticFeedback.selectionClick();
              state.selectBox(b);
            },
          ),
        // LIVE badge
        if (state.phoneCamera.isStreaming)
          Positioned(
            top: 8, right: 8,
            child: _LiveBadge(),
          ),
        // Detection count badge
        if (state.currentBoxes.isNotEmpty)
          Positioned(
            top: 8, left: 8,
            child: _DetectionCountBadge(count: state.currentBoxes.length),
          ),
        // Hint when no box selected
        if (state.selectedBox == null && state.currentBoxes.isNotEmpty)
          Positioned(
            bottom: 12, left: 0, right: 0,
            child: Center(
              child: _HintChip(
                text: state.isArabic ? 'اضغط على صندوق للتحليل' : 'Tap a box to analyze',
              ),
            ),
          ),
        // Analyzing overlay — when Moondream + LLM are running
        if (state.chatSession == null && state.firstLlmContext != null)
          Positioned.fill(
            child: Container(
              color: Colors.black54,
              child: Center(
                child: _AnalyzingOverlay(state: state),
              ),
            ),
          ),
      ],
    );
  }
}

// ===========================================================================
// BADGES & CHIPS
// ===========================================================================
class _LiveBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: palette.AppColors.danger,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 6, color: Colors.white),
          const SizedBox(width: 4),
          Text('LIVE', style: GoogleFonts.spaceMono(
              color: Colors.white, fontSize: 10,
              fontWeight: FontWeight.w700, letterSpacing: 1.1)),
        ],
      ),
    );
  }
}

class _DetectionCountBadge extends StatelessWidget {
  final int count;
  const _DetectionCountBadge({required this.count});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: palette.AppColors.dustyLavender.withOpacity(0.85),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.center_focus_strong, size: 12, color: Colors.white),
          const SizedBox(width: 4),
          Text('$count detected', style: GoogleFonts.rubik(
              color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
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
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(text,
          style: GoogleFonts.rubik(color: Colors.white, fontSize: 12)),
    );
  }
}

class _AutoFlashBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: palette.AppColors.dustyMauve,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('AUTO',
          style: GoogleFonts.spaceMono(
              color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700)),
    );
  }
}

class _AnalyzingOverlay extends StatelessWidget {
  final RecognitionState state;
  const _AnalyzingOverlay({required this.state});
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 48, height: 48,
          child: CircularProgressIndicator(
            strokeWidth: 4,
            color: palette.AppColors.dustyMauve,
          ),
        ),
        const SizedBox(height: 12),
        Text('Analyzing with Moondream AI…',
            style: GoogleFonts.rubik(color: Colors.white, fontSize: 13)),
      ],
    );
  }
}

// ===========================================================================
// ANIMATED ICON BUTTON — scale feedback on tap
// ===========================================================================
class _AnimatedIconButton extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1.0, end: 1.0),
      duration: const Duration(milliseconds: 100),
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: IconButton(
        icon: Icon(icon, color: color, size: 22),
        tooltip: tooltip,
        onPressed: () {
          HapticFeedback.selectionClick();
          onTap();
        },
      ),
    );
  }
}
