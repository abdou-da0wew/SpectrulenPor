import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../utils/app_theme.dart' as palette;

/// Shows the latest frame received from the ESP32-CAM over Bluetooth.
/// Falls back to a placeholder when no frame is available yet.
class CameraPreviewWidget extends StatelessWidget {
  final Uint8List? jpegBytes;
  final DateTime? capturedAt;
  final bool isLive;

  const CameraPreviewWidget({
    super.key,
    this.jpegBytes,
    this.capturedAt,
    this.isLive = false,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: Container(
          color: palette.AppColors.inkDark,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (jpegBytes != null)
                Image.memory(
                  jpegBytes!,
                  gaplessPlayback: true,
                  fit: BoxFit.cover,
                )
              else
                const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.videocam_off,
                          size: 56, color: palette.AppColors.silver),
                      SizedBox(height: 12),
                      Text(
                        'Waiting for the glasses to send a frame...',
                        style: TextStyle(color: palette.AppColors.silver),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              // Brand gradient scrim at bottom for the timestamp legibility
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Container(
                    height: 48,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          palette.AppColors.inkDark.withOpacity(0.0),
                          palette.AppColors.inkDark.withOpacity(0.7),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (isLive)
                Positioned(
                  top: 10,
                  right: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: palette.AppColors.danger,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, size: 8, color: Colors.white),
                        SizedBox(width: 6),
                        Text('LIVE',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                                letterSpacing: 1.1)),
                      ],
                    ),
                  ),
                ),
              if (capturedAt != null)
                Positioned(
                  bottom: 8,
                  left: 10,
                  child: Text(
                    _format(capturedAt!),
                    style: const TextStyle(
                        color: palette.AppColors.alabasterGrey, fontSize: 11),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _format(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
