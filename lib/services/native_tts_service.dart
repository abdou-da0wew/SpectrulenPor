import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_tts/flutter_tts.dart';

/// Offline speech fallback with a deliberately slower narration rate.
/// When available, the service prefers the best-quality installed offline
/// voice matching the current language.
class NativeTtsService {
  NativeTtsService._();
  static final NativeTtsService instance = NativeTtsService._();

  FlutterTts? _tts;
  bool _ready = false;
  bool get isReady => _ready;

  String _language = 'en-US';
  String? _selectedVoice;
  String? get selectedVoice => _selectedVoice;

  static double _rate = 0.43;
  static const double _pitch = 1.0;
  static const double _volume = 1.0;

  Future<void> init() async {
    try {
      _tts = FlutterTts();
      await _tts!.setLanguage(_language);
      await _tts!.setSpeechRate(_rate);
      await _tts!.setPitch(_pitch);
      await _tts!.setVolume(_volume);
      await _tts!.awaitSpeakCompletion(true);
      await _selectBestOfflineVoice();
      _ready = true;
    } on MissingPluginException {
      debugPrint('[NativeTts] plugin unavailable on this platform.');
      _ready = false;
    } catch (error) {
      debugPrint('[NativeTts] init failed: $error');
      _ready = false;
    }
  }

  Future<void> _selectBestOfflineVoice() async {
    final tts = _tts;
    if (tts == null) return;

    try {
      final rawVoices = await tts.getVoices;
      if (rawVoices is! List) return;
      final language = _language.split('-').first.toLowerCase();
      final requestedLocale = _language.replaceAll('_', '-').toLowerCase();
      final candidates = <Map<String, dynamic>>[];

      for (final raw in rawVoices) {
        if (raw is! Map) continue;
        final voice = Map<String, dynamic>.from(raw);
        final locale = (voice['locale'] ?? '').toString().replaceAll('_', '-');
        if (!locale.toLowerCase().startsWith(language)) continue;
        if (voice['network_required'] == true) continue;
        candidates.add(voice);
      }

      if (candidates.isEmpty) return;
      int score(Map<String, dynamic> voice) {
        final locale = (voice['locale'] ?? '')
            .toString()
            .replaceAll('_', '-')
            .toLowerCase();
        final exact = locale == requestedLocale ? 1000 : 0;
        final quality = (voice['quality'] as num?)?.toInt() ?? 0;
        final latency = (voice['latency'] as num?)?.toInt() ?? 0;
        return exact + quality - latency;
      }

      candidates.sort((a, b) => score(b).compareTo(score(a)));
      final best = candidates.first;
      final name = (best['name'] ?? '').toString();
      final locale = (best['locale'] ?? _language).toString();
      if (name.isEmpty || locale.isEmpty) return;
      await tts.setVoice({'name': name, 'locale': locale});
      _selectedVoice = '$name ($locale, offline)';
    } catch (error) {
      // Some Android engines expose voice metadata but reject setVoice().
      // In that case, keep the engine's installed local default voice.
      debugPrint('[NativeTts] offline voice selection skipped: $error');
    }
  }

  Future<void> setLanguage(String language) async {
    _language = language;
    try {
      await _tts?.setLanguage(language);
      await _selectBestOfflineVoice();
    } catch (_) {}
  }

  Future<void> setRate(double rate) async {
    _rate = rate.clamp(0.38, 0.75).toDouble();
    try {
      await _tts?.setSpeechRate(_rate);
    } catch (_) {}
  }

  Future<void> speak(String text) async {
    final clean = text.trim();
    if (!_ready || clean.isEmpty) return;
    try {
      await _tts!.stop();
      await _tts!.speak(clean, focus: true);
    } catch (error) {
      debugPrint('[NativeTts] speak failed: $error');
    }
  }

  Future<void> stop() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }

  void dispose() {
    unawaited(stop());
  }
}
