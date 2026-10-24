import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// Runtime secret bootstrap for SpectruLenPor.
///
/// The three demo keys are stored in `assets/config/secrets.json`, which is
/// **gitignored** (GitHub push-protection blocks committed API keys). A
/// committed template lives at `assets/config/secrets.example.json`:
///
///     cp assets/config/secrets.example.json assets/config/secrets.json
///     # …then paste your keys
///
/// Resolution order for every key:
///   1. SharedPreferences (Settings screen hot-swap)  — handled by callers
///   2. `assets/config/secrets.json`                  — local demo build
///   3. `--dart-define=MOONDREAM_API_KEY=…` etc.      — CI / release builds
///   4. '' → cloud tiers disabled, offline cascade runs
class AppSecrets {
  AppSecrets._();
  static Map<String, String>? _cache;

  static Future<Map<String, String>> load() async {
    if (_cache != null) return _cache!;
    try {
      final raw = await rootBundle.loadString('assets/config/secrets.json');
      _cache = (jsonDecode(raw) as Map).cast<String, String>();
    } catch (_) {
      // Missing file (fresh clone / CI) — fall through to dart-defines.
      _cache = const {};
    }
    return _cache!;
  }

  static Future<String> moondreamKey() async => (await load())['moondream'] ??
      const String.fromEnvironment('MOONDREAM_API_KEY');

  static Future<String> openRouterLlmKey() async =>
      (await load())['openrouter_llm'] ??
      const String.fromEnvironment('OPENROUTER_LLM_KEY');

  static Future<String> openRouterTtsKey() async =>
      (await load())['openrouter_tts'] ??
      const String.fromEnvironment('OPENROUTER_TTS_KEY');
}
