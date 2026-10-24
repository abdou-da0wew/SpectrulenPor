import 'package:flutter/material.dart';

import '../models/recognition_state.dart';
import '../utils/app_theme.dart' as palette;

/// Small chip that shows the instant on-device label coming from
/// Moondream2 / ML Kit, with an icon indicating the source.
class LiveLabelChip extends StatelessWidget {
  final String? label;
  final VisionSource source;

  const LiveLabelChip({
    super.key,
    required this.label,
    required this.source,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _sourceColor(source);
    final icon = _sourceIcon(source);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: palette.AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.55), width: 1.2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: color.withOpacity(0.15),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Local vision — instant',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  label ?? 'Idle — waiting for next frame.',
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(color: palette.AppColors.inkDark),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _sourceColor(VisionSource s) {
    switch (s) {
      case VisionSource.mlkit:
        return palette.AppColors.dustyMauve; // fast path accent
      case VisionSource.moondream:
        return palette.AppColors.dustyLavender; // deeper AI accent
      case VisionSource.error:
        return palette.AppColors.danger;
      case VisionSource.idle:
        return palette.AppColors.silver;
    }
  }

  IconData _sourceIcon(VisionSource s) {
    switch (s) {
      case VisionSource.mlkit:
        return Icons.flash_on;
      case VisionSource.moondream:
        return Icons.auto_awesome;
      case VisionSource.error:
        return Icons.error_outline;
      case VisionSource.idle:
        return Icons.pause_circle_outline;
    }
  }
}
