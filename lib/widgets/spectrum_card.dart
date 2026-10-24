import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

import '../models/spectrum_reading.dart';
import '../utils/app_theme.dart' as palette;

/// Spectrum analysis panel: UV + IR channel gauges, state of matter chip,
/// and confidence bars for the specialized model's top predictions.
/// Mirrors the paper's core loop: sensors -> phone -> analysis -> voice.
class SpectrumCard extends StatelessWidget {
  final SpectrumReading? reading;
  final List<(String, double)>? predictions;
  final MatterState state;
  final bool hazardActive;
  final bool hasTelemetry;

  const SpectrumCard({
    super.key,
    required this.reading,
    required this.predictions,
    required this.state,
    required this.hazardActive,
    required this.hasTelemetry,
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
                      palette.AppColors.dustyMauve.withOpacity(0.14),
                  child: const Icon(Icons.ssid_chart,
                      size: 18, color: palette.AppColors.dustyMauve),
                ),
                const SizedBox(width: 10),
                Text(AppLocalizations.of(context).spectrum,
                    style: theme.textTheme.titleMedium),
              ],
            ),
            const Divider(height: 20),

            if (!hasTelemetry)
              Text(
                AppLocalizations.of(context).noSensorData,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: palette.AppColors.inkSoft),
              )
            else ...[
              _ChannelBar(
                label: AppLocalizations.of(context).uvChannel,
                icon: Icons.wb_sunny_outlined,
                value: reading!.uvPercent,
                raw: reading!.uvRaw,
                warn: reading!.uvHazard,
              ),
              const SizedBox(height: 10),
              _ChannelBar(
                label: AppLocalizations.of(context).irChannel,
                icon: Icons.thermostat,
                value: reading!.irPercent,
                raw: reading!.irRaw,
                warn: reading!.irHazard,
              ),
            ],

            const SizedBox(height: 14),

            // State of matter chip
            Row(
              children: [
                Text('${AppLocalizations.of(context).stateMatter}: ',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                _StateChip(state: state),
              ],
            ),

            // Specialized model top predictions (if ONNX path ran)
            if (predictions != null && predictions!.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                'ONNX top-3',
                style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: palette.AppColors.inkSoft,
                    letterSpacing: 0.4),
              ),
              const SizedBox(height: 6),
              for (final (label, conf) in predictions!.take(3))
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: Text(label,
                            style: theme.textTheme.bodyMedium,
                            overflow: TextOverflow.ellipsis),
                      ),
                      Expanded(
                        flex: 2,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: conf,
                            minHeight: 6,
                            backgroundColor: palette.AppColors.dustGrey,
                            color: palette.AppColors.dustyMauve,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 42,
                        child: Text(
                          '${(conf * 100).toStringAsFixed(0)}%',
                          style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: palette.AppColors.dustyLavender),
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ChannelBar extends StatelessWidget {
  final String label;
  final IconData icon;
  final double value; // 0..100
  final int raw;
  final bool warn;

  const _ChannelBar({
    required this.label,
    required this.icon,
    required this.value,
    required this.raw,
    required this.warn,
  });

  @override
  Widget build(BuildContext context) {
    final color = warn ? palette.AppColors.danger : palette.AppColors.dustyMauve;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13.5)),
            const Spacer(),
            Text('$raw  ·  ${value.toStringAsFixed(0)}%',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: color)),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: LinearProgressIndicator(
            value: value / 100,
            minHeight: 9,
            backgroundColor: palette.AppColors.dustGrey,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _StateChip extends StatelessWidget {
  final MatterState state;
  const _StateChip({required this.state});

  @override
  Widget build(BuildContext context) {
    final (text, icon, color) = switch (state) {
      MatterState.solid => (
          AppLocalizations.of(context).stateSolid,
          Icons.category_outlined,
          palette.AppColors.dustyLavender
        ),
      MatterState.liquid => (
          AppLocalizations.of(context).stateLiquid,
          Icons.water_drop_outlined,
          palette.AppColors.dustyMauve
        ),
      MatterState.gas => (
          AppLocalizations.of(context).stateGas,
          Icons.air,
          palette.AppColors.warning
        ),
      MatterState.unknown => (
          AppLocalizations.of(context).stateUnknown,
          Icons.help_outline,
          palette.AppColors.silver
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 5),
          Text(text,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w700, fontSize: 12.5)),
        ],
      ),
    );
  }
}
