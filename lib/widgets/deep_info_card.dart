import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../models/recognition_state.dart';
import '../utils/app_theme.dart' as palette;
import '../utils/strings.dart';

/// Renders the streaming deep-reasoning markdown returned by OpenRouter.
/// Shows a progress indicator while we wait for the first chunk.
class DeepInfoCard extends StatelessWidget {
  final String markdown;
  final UpstreamStatus status;

  const DeepInfoCard({
    super.key,
    required this.markdown,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor:
                      palette.AppColors.dustyLavender.withOpacity(0.12),
                  child: const Icon(Icons.psychology,
                      color: palette.AppColors.dustyLavender, size: 18),
                ),
                const SizedBox(width: 10),
                Text(S.t(context, S.deepReasoning),
                    style: theme.textTheme.titleMedium),
                const Spacer(),
                _statusBadge(theme),
              ],
            ),
            const Divider(height: 20),
            if (markdown.isEmpty && status == UpstreamStatus.waiting)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(),
              )
            else if (markdown.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  S.t(context, S.deepHint),
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: palette.AppColors.inkSoft),
                ),
              )
            else
              MarkdownBody(
                data: markdown,
                selectable: true,
                styleSheet: MarkdownStyleSheet(
                  p: theme.textTheme.bodyLarge
                      ?.copyWith(color: palette.AppColors.inkDark),
                  h2: theme.textTheme.titleMedium?.copyWith(
                    color: palette.AppColors.dustyLavender,
                    fontWeight: FontWeight.w700,
                  ),
                  h3: theme.textTheme.titleSmall?.copyWith(
                    color: palette.AppColors.dustyMauve,
                    fontWeight: FontWeight.w700,
                  ),
                  listBullet: theme.textTheme.bodyLarge
                      ?.copyWith(color: palette.AppColors.inkDark),
                  strong: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: palette.AppColors.inkDark,
                  ),
                  blockquoteDecoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                          color: palette.AppColors.dustyMauve, width: 3),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusBadge(ThemeData theme) {
    final (text, color) = switch (status) {
      UpstreamStatus.idle => ('Idle', palette.AppColors.silver),
      UpstreamStatus.waiting => ('Waiting…', palette.AppColors.warning),
      UpstreamStatus.streaming => ('Streaming…', palette.AppColors.dustyMauve),
      UpstreamStatus.done => ('Done', palette.AppColors.success),
      UpstreamStatus.error => ('Error', palette.AppColors.danger),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }
}
