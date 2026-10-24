import 'package:flutter/material.dart';

import '../utils/app_theme.dart' as palette;
import '../utils/strings.dart';

/// Row of large, accessibility-friendly action buttons:
///   * "Describe now"  -> manual capture + analyze (works even when
///     continuous streaming is off, saving BLE bandwidth & battery).
///   * Mute / unmute   -> toggles spoken narration.
/// Buttons use >= 48 dp height and strong contrast for visually impaired users.
class AudioControls extends StatelessWidget {
  final bool speaking;
  final bool busy;
  final VoidCallback onDescribeNow;
  final VoidCallback onToggleSpeak;

  const AudioControls({
    super.key,
    required this.speaking,
    required this.busy,
    required this.onDescribeNow,
    required this.onToggleSpeak,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: SizedBox(
              height: 54,
              child: FilledButton.icon(
                onPressed: busy ? null : onDescribeNow,
                icon: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.center_focus_strong),
                label: Text(busy
                    ? S.t(context, S.analyzing)
                    : S.t(context, S.describeNow)),
                style: FilledButton.styleFrom(
                  backgroundColor: busy
                      ? palette.AppColors.dustyMauve
                      : palette.AppColors.dustyLavender,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: SizedBox(
              height: 54,
              child: OutlinedButton.icon(
                onPressed: onToggleSpeak,
                icon: Icon(speaking ? Icons.volume_up : Icons.volume_off),
                label: Text(speaking
                    ? S.t(context, S.soundOn)
                    : S.t(context, S.muted)),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(
                    color: speaking
                        ? palette.AppColors.dustyMauve
                        : palette.AppColors.silver,
                    width: 1.4,
                  ),
                  foregroundColor: speaking
                      ? palette.AppColors.dustyMauve
                      : palette.AppColors.inkSoft,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
