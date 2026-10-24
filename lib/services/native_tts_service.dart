import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

/// Wraps the Android native TextToSpeech engine for the low-latency
/// "live label" narration path (e.g. "In front of you is a glass beaker.").
///
/// We keep this separate from `OpenRouterTtsService` so the live path
/// never depends on the network.
class NativeTtsService {
  NativeTtsService._();
  static final NativeTtsService instance = NativeTtsService._();

  FlutterTts? _tts;
  bool _ready = false;
  bool get isReady => _ready;

  String _language = 'en-US';
  double _rate = 1.0;     // 0.5..2.0, 1.0 normal
  double _pitch = 1.0;

  Future<void> init() async {
    _tts = FlutterTts();
    await _tts!.setLanguage(_language);
    await _tts!.setSpeechRate(_rate);
    await _tts!.setPitch(_pitch);
    await _tts!.awaitSpeakCompletion(true);
    _ready = true;
  }

  Future<void> setLanguage(String lang) async {
    _language = lang;
    await _tts?.setLanguage(lang);
  }

  Future<void> setRate(double r) async {
    _rate = r.clamp(0.5, 2.0);
    await _tts?.setSpeechRate(_rate);
  }

  Future<void> speak(String text) async {
    if (!_ready || text.isEmpty) return;
    // Stop any in-progress narration so the new sentence takes over.
    await _tts!.stop();
    await _tts!.speak(text);
  }

  Future<void> stop() async {
    await _tts?.stop();
  }

  void dispose() {
    _tts?.stop();
  }
}
