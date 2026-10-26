import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Android-built-in SpeechRecognizer wrapper for chat voice input.
///
/// Uses the `speech_to_text` plugin which calls Android's native
/// SpeechRecognizer (the same one Google Assistant uses). No Google cloud
/// call — all on-device. Supports ar-EG and en-US.
class MicService {
  MicService._();
  static final MicService instance = MicService._();

  final SpeechToText _stt = SpeechToText();
  bool _ready = false;
  bool _listening = false;

  bool get isReady => _ready;
  bool get isListening => _listening;

  Future<void> init() async {
    if (_ready) return;
    _ready = await _stt.initialize(
      onError: (e) => debugPrint('[Mic] error: $e.errorMsg'),
      onStatus: (s) => debugPrint('[Mic] status: $s'),
    );
  }

  /// Start listening. Calls [onResult] with the recognized text (partial +
  /// final). The caller can keep appending to the chat input field.
  Future<void> startListen({
    required Function(String text, bool isFinal) onResult,
    String localeId = 'en-US',
  }) async {
    if (!_ready || _listening) return;
    _listening = true;
    await _stt.listen(
      onResult: (r) => onResult(r.recognizedWords, r.finalResult),
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
      partialResults: true,
      localeId: localeId,
      cancelOnError: true,
      listenMode: ListenMode.dictation,
    );
  }

  Future<void> stop() async {
    if (!_listening) return;
    await _stt.stop();
    _listening = false;
  }

  /// List available locales — call to find ar-EG / ar-SA etc.
  Future<List<LocaleName>> locales() async {
    if (!_ready) return const [];
    return await _stt.locales();
  }
}
