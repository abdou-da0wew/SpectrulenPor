import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/bounding_box.dart';
import '../models/bluetooth_status.dart';
import '../models/recognition_state.dart';
import '../utils/app_theme.dart' as palette;
import '../widgets/bounding_box_overlay.dart';
import 'chat_screen.dart';

/// Home screen (v5.0) — camera preview with YOLO bounding box overlay +
/// tap-to-select + "Analyze this" FAB + chat navigation.
///
/// Replaces the v3.3 camera preview widget with a proper full-bleed camera
/// view that fills its container (fixed "shrunk preview" complaint).
class HomeScreenV5 extends StatelessWidget {
  const HomeScreenV5({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RecognitionState>();
    final loc = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: palette.AppColors.alabasterGrey,
      appBar: AppBar(
        backgroundColor: palette.AppColors.dustyLavender,
        title: Text(
          'SpectruLenPor',
          style: GoogleFonts.jaro().copyWith(color: Colors.white),
        ),
        actions: [
          // Flashlight
          IconButton(
            icon: Icon(
              state.flashOn ? Icons.flashlight_on : Icons.flashlight_off,
              color: state.flashOn ? palette.AppColors.warning : null,
            ),
            onPressed: () => state.setFlashlight(!state.flashOn),
          ),
          // Cloud-only toggle quick-access
          IconButton(
            icon: Icon(
              state.cloudOnly ? Icons.cloud_off : Icons.cloud,
              color: state.cloudOnly ? palette.AppColors.warning : null,
            ),
            tooltip: state.cloudOnly ? 'Cloud-only ON' : 'Cloud-only OFF',
            onPressed: () => state.cloudOnly = !state.cloudOnly,
          ),
          TextButton(
            onPressed: () async {
              final next = state.isArabic ? 'en' : 'ar';
              await state.setLocale(next);
            },
            child: Text(
              state.isArabic ? 'EN' : 'ع',
              style: GoogleFonts.rubik().copyWith(
                color: Colors.white, fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white),
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
      body: Column(
        children: [
          // Status bar — connection / source / gate
          _StatusBar(state: state),
          // Source toggle (Phone camera / Glasses)
          _SourceToggle(state: state),
          // Camera preview — FIXED: full-bleed AspectRatio that fills container
          Expanded(child: _CameraPreviewV5(state: state)),
          // Bottom: live label chip + Analyze FAB + spectrum card
          _BottomBar(state: state, loc: loc),
        ],
      ),
      floatingActionButton:
          state.selectedBox != null && state.chatSession == null
              ? FloatingActionButton.extended(
                  onPressed: () => state.captureAndAnalyzeSelected(),
                  backgroundColor: palette.AppColors.dustyMauve,
                  icon: const Icon(Icons.science, color: Colors.white),
                  label: Text(
                    'Analyze ${state.selectedBox!.label}',
                    style: GoogleFonts.rubik().copyWith(color: Colors.white),
                  ),
                )
              : state.chatSession != null
                  ? FloatingActionButton.extended(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const ChatScreen()),
                      ),
                      backgroundColor: palette.AppColors.dustyLavender,
                      icon: const Icon(Icons.chat, color: Colors.white),
                      label: Text(
                        'Open chat',
                        style: GoogleFonts.rubik().copyWith(color: Colors.white),
                      ),
                    )
                  : null,
    );
  }
}

class _StatusBar extends StatelessWidget {
  final RecognitionState state;
  const _StatusBar({required this.state});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: palette.AppColors.alabasterGrey,
      child: Row(
        children: [
          Icon(state.btStatus == BluetoothStatus.connected ? Icons.bluetooth_connected
                : Icons.bluetooth_disabled, size: 16, color: palette.AppColors.dustyLavender),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              state.btStatus == BluetoothStatus.connected
                  ? 'Glasses connected'
                  : 'Phone camera mode',
              style: GoogleFonts.rubik().copyWith(fontSize: 12),
            ),
          ),
          if (state.lastGate != null)
            Text(
              '${state.lastGate!.reason} · ${state.lastGate!.brightness.toStringAsFixed(0)}',
              style: GoogleFonts.spaceMono().copyWith(fontSize: 10),
            ),
          if (state.autoFlashOn)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: palette.AppColors.dustyMauve,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('AUTO',
                style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
            ),
        ],
      ),
    );
  }
}

class _SourceToggle extends StatelessWidget {
  final RecognitionState state;
  const _SourceToggle({required this.state});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(child: _segButton('Phone camera', state.source == CameraSource.phone,
              () => state.switchSource(CameraSource.phone))),
          Expanded(child: _segButton('Glasses', state.source == CameraSource.glasses,
              () => state.switchSource(CameraSource.glasses))),
        ],
      ),
    );
  }

  Widget _segButton(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: active ? palette.AppColors.dustyLavender : Colors.white,
          border: Border.all(color: palette.AppColors.dustyLavender, width: 1),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: GoogleFonts.rubik().copyWith(
            color: active ? Colors.white : palette.AppColors.dustyLavender,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _CameraPreviewV5 extends StatelessWidget {
  final RecognitionState state;
  const _CameraPreviewV5({required this.state});
  @override
  Widget build(BuildContext context) {
    final frame = state.lastFrame;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (frame != null)
          Container(
            color: Colors.black,
            child: FittedBox(
              fit: BoxFit.cover,
              child: AspectRatio(
                aspectRatio: frame.width / frame.height,
                child: Image.memory(
                  frame.jpegBytes,
                  gaplessPlayback: true,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          )
        else
          Container(
            color: palette.AppColors.inkDark,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.videocam_off, size: 56, color: Colors.white70),
                  const SizedBox(height: 12),
                  Text(
                    state.isArabic ? 'في انتظار إطار...' : 'Waiting for a frame…',
                    style: GoogleFonts.rubik().copyWith(color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
        // Bounding box overlay
        if (frame != null && state.currentBoxes.isNotEmpty)
          BoundingBoxOverlay(
            boxes: state.currentBoxes,
            selectedBox: state.selectedBox,
            onTapBox: (b) => state.selectBox(b),
          ),
        // Top-right: LIVE badge
        if (state.phoneCamera.isStreaming)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: palette.AppColors.danger,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, size: 6, color: Colors.white),
                  SizedBox(width: 4),
                  Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.1)),
                ],
              ),
            ),
          ),
        // Center hint: tap a box to analyze
        if (state.selectedBox == null && state.currentBoxes.isNotEmpty)
          Positioned(
            bottom: 12,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  state.isArabic ? 'اضغط على صندوق للتحليل' : 'Tap a box to analyze',
                  style: GoogleFonts.rubik().copyWith(color: Colors.white, fontSize: 11),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _BottomBar extends StatelessWidget {
  final RecognitionState state;
  final AppLocalizations loc;
  const _BottomBar({required this.state, required this.loc});
  @override
  Widget build(BuildContext context) {
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
          Text(
            state.isArabic ? 'التحليل اللحظي' : 'Live analysis',
            style: GoogleFonts.jaro().copyWith(
              color: palette.AppColors.dustyLavender, fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            state.lastLabel ?? (state.isArabic ? 'في انتظار التحليل…' : 'Waiting for analysis…'),
            style: GoogleFonts.spaceMono().copyWith(fontSize: 11),
          ),
          if (state.upstreamStatus != UpstreamStatus.idle) ...[
            const SizedBox(height: 4),
            Text(
              state.isArabic ? 'السحابة: ${state.upstreamStatus.name}' : 'Cloud: ${state.upstreamStatus.name}',
              style: GoogleFonts.rubik().copyWith(fontSize: 10, color: palette.AppColors.silver),
            ),
          ],
        ],
      ),
    );
  }
}
