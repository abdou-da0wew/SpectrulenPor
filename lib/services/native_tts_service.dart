import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;
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
  double _rate = 1.0; // 0.5..2.0, 1.0 normal
  final double _pitch = 1.0;

  Future<void> init() async {
    try {
      _tts = FlutterTts();
      await _tts!.setLanguage(_language);
      await _tts!.setSpeechRate(_rate);
      await _tts!.setPitch(_pitch);
      await _tts!.awaitSpeakCompletion(true);
      _ready = true;
    } on MissingPluginException {
      debugPrint('[NativeTts] plugin unavailable on this platform.');
      _ready = false;
    } catch (e) {
      debugPrint('[NativeTts] init failed: $e');
      _ready = false;
    }
  }

  Future<void> setLanguage(String lang) async {
    _language = lang;
    try {
      await _tts?.setLanguage(lang);
    } catch (_) {}
  }

  Future<void> setRate(double r) async {
    _rate = r.clamp(0.5, 2.0);
    try {
      await _tts?.setSpeechRate(_rate);
    } catch (_) {}
  }

  Future<void> speak(String text) async {
    if (!_ready || text.isEmpty) return;
    try {
      await _tts!.stop();
      await _tts!.speak(text);
    } catch (e) {
      debugPrint('[NativeTts] speak failed: $e');
    }
  }

  Future<void> stop() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }

  void dispose() {
    stop();
  }
}
