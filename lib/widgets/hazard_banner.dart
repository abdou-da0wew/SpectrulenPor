import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../utils/app_theme.dart' as palette;
import '../utils/app_icons.dart';

/// Pulsing red banner shown when a hazard is detected — either by keyword
/// analysis of the AI reply or by UV/IR sensor thresholds. Designed to be
/// impossible to miss (accessibility first).
class HazardBanner extends StatelessWidget {
  final String reason;
  final VoidCallback onDismiss;

  const HazardBanner({
    super.key,
    required this.reason,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: palette.AppColors.danger,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: palette.AppColors.danger.withValues(alpha: 0.4),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(AppIcons.warningAmberRounded,
              color: Colors.white, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizations.of(context).hazardDetected,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  AppLocalizations.of(context).hazardSpeech,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 13, height: 1.3),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(AppIcons.close, color: Colors.white, size: 20),
            onPressed: onDismiss,
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          ),
        ],
      ),
    );
  }
}
