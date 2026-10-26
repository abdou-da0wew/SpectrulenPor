import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../main.dart' show appLocale;
import '../models/recognition_state.dart';
import '../services/local_vision_service.dart';
import '../services/moondream_service.dart';
import '../services/onnx_vision_service.dart';
import '../services/openrouter_service.dart';
import '../services/openrouter_tts_service.dart';
import '../services/phone_camera_service.dart';
import '../utils/app_theme.dart' as palette;
import '../utils/app_typography.dart';

/// Settings — v5.3 pipeline configuration:
///   * Moondream3 cloud API key (primary vision)
///   * OpenRouter API key (presentation + streamed fish-audio TTS)
///   * Text+reasoning fallback chain (gemma → inkling → nemotron)
///   * Language EN/AR (proper l10n + RTL)
///   * Pipeline cadence, camera rotation, local engine status
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _mdKeyCtl;
  late final TextEditingController _orLlmCtl;
  late final TextEditingController _orTtsCtl;

  @override
  void initState() {
    super.initState();
    final prefs = context.read<SharedPreferences>();
    _mdKeyCtl = TextEditingController(
        text: prefs.getString('moondream_api_key') ??
            MoondreamService.instance.apiKey);
    _orLlmCtl = TextEditingController(
        text: prefs.getString('openrouter_llm_key') ??
            prefs.getString('openrouter_api_key') ??
            context.read<OpenRouterService>().apiKey);
    _orTtsCtl = TextEditingController(
        text: prefs.getString('openrouter_tts_key') ??
            (OpenRouterTtsService.instance.isConfigured
                ? '•••••••• (configured)'
                : ''));
  }

  @override
  void dispose() {
    _mdKeyCtl.dispose();
    _orLlmCtl.dispose();
    _orTtsCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RecognitionState>();
    final prefs = context.read<SharedPreferences>();
    final theme = Theme.of(context);
    final onnx = OnnxVisionService.instance;
    final md = MoondreamService.instance;
    final l = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l.settings)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          // ---------------- Language ----------------
          _sectionHeader(theme, Icons.translate, 'Language · اللغة'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'en', label: Text('English')),
                  ButtonSegment(value: 'ar', label: Text('العربية')),
                ],
                selected: {state.localeCode.startsWith('ar') ? 'ar' : 'en'},
                onSelectionChanged: (sel) async {
                  await state.setLocale(sel.first);
                  appLocale.value = Locale(sel.first);
                },
                style: SegmentedButton.styleFrom(
                  selectedBackgroundColor: palette.AppColors.dustyLavender,
                  selectedForegroundColor: Colors.white,
                ),
              ),
            ),
          ),

          // ---------------- Moondream3 cloud (primary vision) ----------------
          _sectionHeader(theme, Icons.auto_awesome,
              'Moondream3 cloud — primary vision'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _mdKeyCtl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: l.moondreamApiKeyLabel,
                      helperText: l.moondreamApiKeyHint,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) {
                      prefs.setString('moondream_api_key', v);
                      md.apiKey = v;
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        md.isCloudConfigured
                            ? Icons.cloud_done
                            : Icons.cloud_off,
                        size: 18,
                        color: md.isCloudConfigured
                            ? palette.AppColors.success
                            : palette.AppColors.silver,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          md.isCloudConfigured
                              ? l.moondreamCloudEnabled
                              : l.moondreamCloudDisabled,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: palette.AppColors.inkSoft),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Fallbacks when offline / rate-limited (2 req/s): local '
                    'Moondream GGUF → ONNX classifier → ML Kit OCR.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: palette.AppColors.inkSoft),
                  ),
                ],
              ),
            ),
          ),

          // ---------------- OpenRouter (LLM + TTS keys) ----------------
          _sectionHeader(theme, Icons.key, 'OpenRouter API'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _orLlmCtl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: l.openRouterLlmKeyLabel,
                      helperText: l.openRouterLlmKeyHint,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) {
                      prefs.setString('openrouter_llm_key', v);
                      context.read<OpenRouterService>().apiKey = v;
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _orTtsCtl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: l.openRouterTtsKeyLabel,
                      helperText: l.openRouterTtsKeyHint,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) {
                      prefs.setString('openrouter_tts_key', v);
                      OpenRouterTtsService.instance.configure(apiKey: v);
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Moondream3 produces the factual analysis; the LLM only '
                    'presents it — short prompts, low latency, streamed.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: palette.AppColors.inkSoft),
                  ),
                ],
              ),
            ),
          ),

          // ---------------- Text+reasoning chain ----------------
          _sectionHeader(theme, Icons.psychology_alt, l.upstreamFallbackHeader),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  for (var i = 0;
                      i < OpenRouterService.modelChain.length;
                      i++)
                    RadioListTile<int>(
                      title: Text(
                        switch (i) {
                          0 => l.modelGemma26,
                          1 => l.modelInkling,
                          _ => l.modelNemotron,
                        },
                        style: const TextStyle(fontSize: 13.5),
                      ),
                      value: i,
                      groupValue: state.upstreamStartModel,
                      onChanged: (v) => state.upstreamStartModel = v!,
                      activeColor: palette.AppColors.dustyLavender,
                    ),
                  const Divider(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l.reasoningTokensLabel,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(l.reasoningTokensHint,
                        style:
                            const TextStyle(fontSize: 12.5, height: 1.4)),
                    value: state.captureReasoningTokens,
                    onChanged: (v) => state.captureReasoningTokens = v,
                  ),
                  if (state.reasoningTokens != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          'Last run reasoning tokens: ${state.reasoningTokens} '
                          '· model: ${state.lastModelUsed}',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: palette.AppColors.dustyLavender,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),

          // ---------------- Diagnostics ----------------
          _sectionHeader(theme, Icons.monitor_heart, l.diagnosticsHeader),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _diagRow(theme, l.diagnosticsCloud,
                      md.isCloudConfigured ? l.moondreamCloudEnabled : l.moondreamCloudDisabled),
                  _diagRow(theme, l.diagnosticsLastModel,
                      state.upstreamStatus == UpstreamStatus.idle
                          ? '—'
                          : state.lastModelUsed),
                  _diagRow(theme, l.diagnosticsReasoningTokens,
                      state.reasoningTokens?.toString() ?? '—'),
                  _diagRow(theme, l.diagnosticsTts,
                      OpenRouterTtsService.ttsModel),
                ],
              ),
            ),
          ),

          // ---------------- Local AI status ----------------
          _sectionHeader(theme, Icons.memory, 'Local AI — offline fallbacks'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _engineRow(
                    theme,
                    ready: onnx.isReady,
                    readyText:
                        'ONNX Runtime Mobile — ${onnx.labelCount} classes loaded',
                    missingText:
                        'No ONNX model bundled — run tooling/'
                        'convert_mobilenet_onnx.py → assets/models/.',
                  ),
                  const SizedBox(height: 8),
                  _engineRow(
                    theme,
                    ready: LocalVisionService.instance.moondreamAvailable,
                    readyText:
                        'Local Moondream GGUF: ${LocalVisionService.instance.moondreamModelPath}',
                    missingText:
                        'Local Moondream not deployed (README → Moondream '
                        'native build). Cloud tier covers it for now.',
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l.ttsNative.split('(').first.trim(),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                        'Speak the instant local label the moment each frame '
                        'is classified (native engine, offline, zero latency).',
                        style:
                            const TextStyle(fontSize: 12.5, height: 1.4)),
                    value: state.liveSpeak,
                    onChanged: (v) => state.liveSpeak = v,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l.deepReasoning,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text(
                        'Streams the local analysis through OpenRouter for a '
                        'cleaner spoken explanation + hazard check. Sentences '
                        'are spoken as they arrive (no full-reply wait).',
                        style: TextStyle(fontSize: 12.5, height: 1.4)),
                    value: state.deepReasonEnabled,
                    onChanged: (v) => state.deepReasonEnabled = v,
                  ),
                ],
              ),
            ),
          ),

          // ---------------- Pipeline ----------------
          _sectionHeader(theme, Icons.speed, 'Pipeline'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('Analysis cadence',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      Text('${state.fps} fps',
                          style: const TextStyle(
                              color: palette.AppColors.dustyLavender,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
                  Slider(
                    value: state.fps.toDouble(),
                    min: 1,
                    max: 4,
                    divisions: 3,
                    label: '${state.fps}',
                    onChanged: (v) => state.fps = v.round(),
                  ),
                  Text(
                    '1 fps is the sweet spot for battery AND for the free '
                    'cloud tiers (Moondream allows 2 req/s).',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: palette.AppColors.inkSoft),
                  ),
                  const Divider(height: 24),
                  Row(
                    children: [
                      const Expanded(
                        child: Text('Camera rotation',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      Text(
                        '${context.read<PhoneCameraService>().quarterTurns * 90}°',
                        style: const TextStyle(
                            color: palette.AppColors.dustyLavender,
                            fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  Slider(
                    value: context
                        .read<PhoneCameraService>()
                        .quarterTurns
                        .toDouble(),
                    min: 0,
                    max: 3,
                    divisions: 3,
                    label:
                        '${context.read<PhoneCameraService>().quarterTurns * 90}°',
                    onChanged: (v) {
                      context.read<PhoneCameraService>().quarterTurns =
                          v.round();
                      setState(() {});
                    },
                  ),
                ],
              ),
            ),
          ),

          // ---------------- TTS ----------------
          _sectionHeader(theme, Icons.record_voice_over, 'Voice output'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l.fishAudioTts,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(l.fishAudioTtsSubtitle,
                        style: const TextStyle(fontSize: 12.5, height: 1.4)),
                    value: state.useOpenRouterTts,
                    onChanged: (v) => state.useOpenRouterTts = v,
                  ),
                  Text(
                    'Model: ${OpenRouterTtsService.ttsModel} — audio bytes are '
                    'streamed into the player as they download (first sound '
                    'without waiting for the full file). When off, the native '
                    'Android engine narrates per-sentence (lowest latency, '
                    'works offline).',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: palette.AppColors.inkSoft),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: state.useOpenRouterTts
                        ? () {
                            OpenRouterTtsService.instance.speakMarkdown(
                                'Voice test. This is SpectruLenPor, your '
                                'spectrum analysis assistant. أنا مساعدك '
                                'الصوتي للتحليل الطيفي.');
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text(
                                      '${l.testVoice} — streaming…')),
                            );
                          }
                        : null,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(l.testVoice),
                  ),
                ],
              ),
            ),
          ),

          // ---------------- About ----------------
          _sectionHeader(theme, Icons.info_outline, 'About'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                l.aboutBody,
                style: AppTypography.paragraphOf(context,
                    color: palette.AppColors.inkSoft),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _diagRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(label,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.AppColors.inkSoft,
                    fontWeight: FontWeight.w700)),
          ),
          Expanded(
            child: Text(value,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.AppColors.dustyLavender,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _engineRow(
    ThemeData theme, {
    required bool ready,
    required String readyText,
    required String missingText,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          ready ? Icons.check_circle : Icons.info_outline,
          size: 18,
          color: ready ? palette.AppColors.success : palette.AppColors.silver,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            ready ? readyText : missingText,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: palette.AppColors.inkSoft, height: 1.4),
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(ThemeData theme, IconData icon, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: palette.AppColors.dustyLavender),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.0,
                color: palette.AppColors.inkSoft,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
