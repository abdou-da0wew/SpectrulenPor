import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/recognition_state.dart';
import '../utils/app_theme.dart' as palette;

/// Small chip that shows the instant on-device label coming from the
/// specialized ONNX model / Moondream / ML Kit, with a source icon.
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
                  AppLocalizations.of(context).localVision,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  label ?? AppLocalizations.of(context).idleLabel,
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
      case VisionSource.moondreamCloud:
        return palette.AppColors.dustyLavender; // primary VLM (cloud)
      case VisionSource.moondreamLocal:
        return palette.AppColors.dustyMauve; // offline VLM
      case VisionSource.onnx:
        return palette.AppColors.inkSoft; // specialized fast path
      case VisionSource.mlkit:
        return palette.AppColors.silver; // fallback
      case VisionSource.error:
        return palette.AppColors.danger;
      case VisionSource.idle:
        return palette.AppColors.silver;
    }
  }

  IconData _sourceIcon(VisionSource s) {
    switch (s) {
      case VisionSource.moondreamCloud:
        return Icons.auto_awesome; // Moondream3 cloud
      case VisionSource.moondreamLocal:
        return Icons.memory; // local GGUF
      case VisionSource.onnx:
        return Icons.bolt; // specialized fast path
      case VisionSource.mlkit:
        return Icons.flash_on;
      case VisionSource.error:
        return Icons.error_outline;
      case VisionSource.idle:
        return Icons.pause_circle_outline;
    }
  }
}
