import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/recognition_state.dart';
import '../services/openrouter_service.dart';
import '../services/openrouter_tts_service.dart';
import '../utils/app_theme.dart' as palette;

/// Settings: OpenRouter API key, upstream model choice, live narration,
/// streaming fps, and OpenRouter TTS configuration.
///
/// Toggles are routed through [RecognitionState] setters so the running
/// pipeline reacts immediately (and values persist via SharedPreferences).
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
        'Gemini 2.5 Flash — fast, balanced (recommended)'),
    ('deepseek/deepseek-chat-v3.1:free', 'DeepSeek V3.1 — strong reasoning'),
    ('meta-llama/llama-3.3-70b-instruct:free', 'Llama 3.3 70B — thorough, slower'),
    ('qwen/qwen3-235b-a22b:free', 'Qwen3 235B — encyclopedic detail'),
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
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
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
                      context.read<SharedPreferences>()
                          .setString('openrouter_api_key', v);
                      // Hot-swap the key into the running service.
                      context.read<OpenRouterService>().apiKey = v;
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Get a free key at openrouter.ai/keys. Free-tier models '
                    'are marked with ":free". The key stays on this device.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: palette.AppColors.inkSoft),
                  ),
                ],
              ),
            ),
          ),

          _sectionHeader(theme, Icons.psychology_alt, 'Upstream model'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  for (final (id, label) in _freeModels)
                    RadioListTile<String>(
                      title:
                          Text(label, style: const TextStyle(fontSize: 14.5)),
                      value: id,
                      groupValue: state.upstreamModel,
                      onChanged: (v) => state.upstreamModel = v!,
                      activeColor: palette.AppColors.dustyLavender,
                    ),
                ],
              ),
            ),
          ),

          _sectionHeader(theme, Icons.speed, 'Live pipeline'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('Speak the local label instantly',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text(
                        'Narrates "In front of you is…" as soon as each frame '
                        'is classified (native TTS, no network).',
                        style: TextStyle(fontSize: 12.5, height: 1.4)),
                    value: state.liveSpeak,
                    onChanged: (v) => state.liveSpeak = v,
                    contentPadding: EdgeInsets.zero,
                  ),
                  SwitchListTile(
                    title: const Text('Deep reasoning upstream',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text(
                        'Sends the local text label to OpenRouter for rich '
                        'context, tips, and related concepts.',
                        style: TextStyle(fontSize: 12.5, height: 1.4)),
                    value: state.deepReasonEnabled,
                    onChanged: (v) => state.deepReasonEnabled = v,
                    contentPadding: EdgeInsets.zero,
                  ),
                  const Divider(),
                  Row(
                    children: [
                      const Expanded(
                        child: Text('Streaming fps',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      Text(
                        '${state.fps} fps',
                        style: const TextStyle(
                            color: palette.AppColors.dustyLavender,
                            fontWeight: FontWeight.w700),
                      ),
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
                    'Higher fps = faster reactions but drains the glasses '
                    'battery and floods BLE. 1 fps is the sweet spot.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: palette.AppColors.inkSoft),
                  ),
                ],
              ),
            ),
          ),

          _sectionHeader(theme, Icons.record_voice_over,
              'OpenRouter TTS (optional)'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    title: const Text('Use OpenRouter TTS for deep replies',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text(
                        'Routes the deep-reasoning text through a premium '
                        'voice. Requires an audio/speech-capable endpoint. '
                        'When off, the Android native engine reads it aloud.',
                        style: TextStyle(fontSize: 12.5, height: 1.4)),
                    value: state.useOpenRouterTts,
                    onChanged: (v) => state.useOpenRouterTts = v,
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _ttsUrlCtl,
                    decoration: const InputDecoration(
                      labelText:
                          'TTS base URL (OpenAI-compatible /audio/speech)',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) =>
                        context.read<SharedPreferences>().setString(
                              'tts_base_url',
                              v,
                            ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _ttsVoiceCtl,
                    decoration: const InputDecoration(
                      labelText: 'Voice (e.g. alloy, echo, fable)',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) =>
                        context.read<SharedPreferences>().setString(
                              'tts_voice',
                              v,
                            ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () {
                      final prefs = context.read<SharedPreferences>();
                      OpenRouterTtsService.instance.configure(
                        apiKey:
                            prefs.getString('openrouter_api_key') ?? '',
                        baseUrl: _ttsUrlCtl.text,
                        voice: _ttsVoiceCtl.text,
                      );
                      OpenRouterTtsService.instance.speakMarkdown(
                          '## Test\nSpectrulenPor voice test. I am your '
                          'smart glasses narrator.');
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

          _sectionHeader(theme, Icons.info_outline, 'About'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                'SpectrulenPor v1.0 — smart scientific glasses that analyze '
                'materials and lab equipment. Pipeline: ESP32-CAM glasses → '
                'Bluetooth → local ML Kit / Moondream vision → OpenRouter '
                'deep reasoning → spoken narration.\n\n'
                'Project by Elaf Al-Tai · Supervised by Dr. Khaled Sibakat · '
                'Computer Science 2025/2026.',
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
