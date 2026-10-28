import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/bluetooth_status.dart';
import '../models/frame_data.dart';
import '../utils/app_theme.dart' as palette;
import '../utils/app_typography.dart';

/// Full-bleed live camera viewport for BLE / JPEG streams.
///
/// Expands to fill the parent viewport (`SizedBox.expand` + `BoxFit.cover`)
/// instead of forcing a shrunk 4:3 letterbox strip, while keeping `gaplessPlayback`
/// so consecutive frames never flicker.
class CameraPreviewWidget extends StatelessWidget {
  final FrameData? frame;
  final BluetoothStatus status;
  final String? liveLabel;

  const CameraPreviewWidget({
    super.key,
    required this.frame,
    required this.status,
    this.liveLabel,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          color: palette.AppColors.inkDark,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: palette.AppColors.silver),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (frame != null)
              _FrameImage(bytes: frame!.jpegBytes)
            else
              _Placeholder(status: status),
            Positioned(
              top: 10,
              left: 10,
              child: _CornerBadge(
                icon: status == BluetoothStatus.connected
                    ? Icons.sensors_rounded
                    : Icons.sensors_off_rounded,
                text: status == BluetoothStatus.connected
                    ? AppLocalizations.of(context).live
                    : status.name.toUpperCase(),
                color: status == BluetoothStatus.connected
                    ? palette.AppColors.success
                    : palette.AppColors.silver,
              ),
            ),
            if (frame != null)
              Positioned(
                top: 10,
                right: 10,
                child: _CornerBadge(
                  icon: Icons.tag_rounded,
                  text: '#${frame!.sequence}',
                  color: palette.AppColors.dustyMauve,
                ),
              ),
            if (liveLabel != null && liveLabel!.isNotEmpty)
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: palette.AppColors.inkDark.withOpacity(0.84),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: palette.AppColors.dustyMauve.withOpacity(0.75),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.graphic_eq_rounded,
                        color: palette.AppColors.alabasterGrey,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          liveLabel!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.bodyOf(
                            context,
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FrameImage extends StatelessWidget {
  final Uint8List bytes;
  const _FrameImage({required this.bytes});

  @override
  Widget build(BuildContext context) {
    return Image.memory(
      bytes,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const Center(
        child: Icon(
          Icons.broken_image_outlined,
          color: palette.AppColors.silver,
          size: 42,
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  final BluetoothStatus status;
  const _Placeholder({required this.status});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final message = switch (status) {
      BluetoothStatus.disconnected => l10n.glassesNotConnected,
      BluetoothStatus.scanning => l10n.scanningGlasses,
      BluetoothStatus.connecting => l10n.negotiatingStream,
      BluetoothStatus.connected => l10n.waitingFirstFrame,
      BluetoothStatus.permissionDenied => l10n.btPermissionsRequired,
      BluetoothStatus.adapterOff => l10n.turnOnBluetooth,
      BluetoothStatus.error => l10n.btConnectionError,
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.visibility_outlined,
              size: 48,
              color: palette.AppColors.dustyMauve,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTypography.bodyOf(
                context,
                color: palette.AppColors.alabasterGrey,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CornerBadge extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _CornerBadge({
    required this.icon,
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: palette.AppColors.inkDark.withOpacity(0.76),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: color.withOpacity(0.75)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}
