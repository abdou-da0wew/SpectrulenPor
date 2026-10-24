import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart' show appLocale;
import '../models/recognition_state.dart';
import '../services/local_vision_service.dart';
import '../services/onnx_vision_service.dart';
import '../services/openrouter_service.dart';
import '../services/openrouter_tts_service.dart';
import '../services/phone_camera_service.dart';
import '../utils/app_theme.dart' as palette;
import '../utils/strings.dart';

/// Settings: OpenRouter API key, upstream model, language (EN/AR),
/// live pipeline (fps / narration), ONNX status, camera rotation,
/// Moondream deployment, and OpenRouter TTS config.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _apiKeyCtl;
  late final TextEditingController _ttsUrlCtl;
  late final TextEditingController _ttsVoiceCtl;

  static const List<(String, String)> _freeModels = [
    ('google/gemini-2.5-flash:free',
        'Gemini 2.5 Flash — fast presenter (recommended)'),
    ('google/gemini-2.5-flash-lite:free',
        'Gemini 2.5 Flash Lite — lowest latency'),
    ('deepseek/deepseek-chat-v3.1:free', 'DeepSeek V3.1 — richer phrasing'),
    ('meta-llama/llama-3.3-70b-instruct:free', 'Llama 3.3 70B — thorough'),
    ('mistralai/mistral-small-3.2-24b-instruct:free',
        'Mistral Small 3.2 — lightweight'),
  ];

  @override
  void initState() {
    super.initState();
    final prefs = context.read<SharedPreferences>();
    _apiKeyCtl =
        TextEditingController(text: prefs.getString('openrouter_api_key') ?? '');
    _ttsUrlCtl = TextEditingController(
        text: prefs.getString('tts_base_url') ??
            'https://openrouter.ai/api/v1');
    _ttsVoiceCtl =
        TextEditingController(text: prefs.getString('tts_voice') ?? 'alloy');
  }

  @override
  void dispose() {
    _apiKeyCtl.dispose();
    _ttsUrlCtl.dispose();
    _ttsVoiceCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RecognitionState>();
    final prefs = context.read<SharedPreferences>();
    final theme = Theme.of(context);
    final onnx = OnnxVisionService.instance;

    return Scaffold(
      appBar: AppBar(title: Text(S.t(context, S.settings))),
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

          // ---------------- OpenRouter ----------------
          _sectionHeader(theme, Icons.key, 'OpenRouter API'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _apiKeyCtl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'API key (sk-or-v1-…)',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) {
                      prefs.setString('openrouter_api_key', v);
                      context.read<OpenRouterService>().apiKey = v;
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Free key: openrouter.ai/keys. The key stays on this '
                    'device. The LLM only presents the specialized model\'s '
                    'analysis — short prompts, low latency.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: palette.AppColors.inkSoft),
                  ),
                ],
              ),
            ),
          ),

          // ---------------- Upstream model ----------------
          _sectionHeader(theme, Icons.psychology_alt, 'Upstream model'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  for (final (id, label) in _freeModels)
                    RadioListTile<String>(
                      title: Text(label,
                          style: const TextStyle(fontSize: 14.5)),
                      value: id,
                      groupValue: state.upstreamModel,
                      onChanged: (v) => state.upstreamModel = v!,
                      activeColor: palette.AppColors.dustyLavender,
                    ),
                ],
              ),
            ),
          ),

          // ---------------- Local AI (ONNX) ----------------
          _sectionHeader(theme, Icons.memory, 'Local AI — ONNX Runtime Mobile'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        onnx.isReady
                            ? Icons.check_circle
                            : Icons.info_outline,
                        size: 18,
                        color: onnx.isReady
                            ? palette.AppColors.success
                            : palette.AppColors.silver,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          onnx.isReady
                              ? 'Specialized model loaded '
                                  '(${onnx.labelCount} classes, optimized)'
                              : 'No ONNX model bundled — using ML Kit '
                                  'fallback. Run tooling/'
                                  'convert_mobilenet_onnx.py and place the '
                                  'files in assets/models/.',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: palette.AppColors.inkSoft),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Speak the local label instantly',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text(
                        'Narrates the specialized model result the moment '
                        'each frame is classified (native TTS, offline).',
                        style: TextStyle(fontSize: 12.5, height: 1.4)),
                    value: state.liveSpeak,
                    onChanged: (v) => state.liveSpeak = v,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('LLM presentation pass',
                        style: TextStyle(fontWeight: FontWeight.w600)),
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
                    '1 fps is the sweet spot for battery; raise it only for '
                    'fast-moving scenes.',
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

          // ---------------- OpenRouter TTS ----------------
          _sectionHeader(theme, Icons.record_voice_over,
              'OpenRouter TTS (optional)'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Use OpenRouter TTS for AI replies',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text(
                        'Premium voice via an OpenAI-compatible '
                        '/audio/speech endpoint. When off, the Android '
                        'native engine speaks (lower latency).',
                        style: TextStyle(fontSize: 12.5, height: 1.4)),
                    value: state.useOpenRouterTts,
                    onChanged: (v) => state.useOpenRouterTts = v,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _ttsUrlCtl,
                    decoration: const InputDecoration(
                      labelText:
                          'TTS base URL (OpenAI-compatible /audio/speech)',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => prefs.setString('tts_base_url', v),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _ttsVoiceCtl,
                    decoration: const InputDecoration(
                      labelText: 'Voice (e.g. alloy, echo, nova)',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => prefs.setString('tts_voice', v),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () {
                      OpenRouterTtsService.instance.configure(
                        apiKey: prefs.getString('openrouter_api_key') ?? '',
                        baseUrl: _ttsUrlCtl.text,
                        voice: _ttsVoiceCtl.text,
                      );
                      OpenRouterTtsService.instance.speakMarkdown(
                          '## Test\nSpectruLenPor voice test. أنا مساعدك '
                          'الصوتي للتحليل الطيفي.');
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Playing TTS test sample…')),
                      );
                    },
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Test voice'),
                  ),
                ],
              ),
            ),
          ),

          // ---------------- Moondream ----------------
          _sectionHeader(theme, Icons.auto_awesome, 'Moondream2 (VLM)'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        LocalVisionService.instance.moondreamAvailable
                            ? Icons.check_circle
                            : Icons.build_circle_outlined,
                        size: 18,
                        color: LocalVisionService
                                .instance.moondreamAvailable
                            ? palette.AppColors.success
                            : palette.AppColors.silver,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          LocalVisionService.instance.moondreamAvailable
                              ? 'GGUF deployed: ${LocalVisionService.instance.moondreamModelPath}'
                              : 'Native engine not deployed. Build the '
                                  'llama.cpp platform channel (README → '
                                  'Moondream native build), push the GGUF to '
                                  'the device, then set the path here.',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: palette.AppColors.inkSoft, height: 1.4),
                        ),
                      ),
                    ],
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
                'SpectruLenPor v2.0 — smart glasses for spectrum analysis and '
                'detection of chemical elements and compounds.\n\n'
                'Pipeline: sensors + camera → ESP32-CAM → Bluetooth → phone '
                '(all processing on-device, ONNX Runtime Mobile) → OpenRouter '
                'presentation pass → bilingual voice narration.\n\n'
                'Malak Adel Sayed Hassan · Grade 1 secondary, Class 3/1 · '
                'Ashmounin Secondary School · Budget: 2,500–6,000 EGP.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.AppColors.inkSoft, height: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(ThemeData theme, IconData icon, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: palette.AppColors.dustyLavender),
          const SizedBox(width: 8),
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
              color: palette.AppColors.inkSoft,
            ),
          ),
        ],
      ),
    );
  }
}
