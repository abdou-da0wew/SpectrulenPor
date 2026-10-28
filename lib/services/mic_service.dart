import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:speech_to_text/speech_to_text.dart';

/// Android-built-in SpeechRecognizer wrapper for chat voice input.
///
/// Uses the `speech_to_text` plugin which calls Android's native
/// SpeechRecognizer (the same one Google Assistant uses). Supports ar-EG and en-US.
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
    try {
      _ready = await _stt.initialize(
        onError: (e) {
          _listening = false;
          debugPrint('[Mic] error: ${e.errorMsg}');
        },
        onStatus: (s) {
          if (s == 'done' || s == 'notListening') {
            _listening = false;
          }
          debugPrint('[Mic] status: $s');
        },
      );
    } on MissingPluginException {
      debugPrint('[Mic] speech_to_text plugin unavailable on this platform.');
      _ready = false;
    } catch (e) {
      debugPrint('[Mic] init failed: $e');
      _ready = false;
    }
  }

  /// Start listening. Calls [onResult] with the recognized text (partial +
  /// final). Automatically resets [isListening] when recognition finishes.
  Future<void> startListen({
    required void Function(String text, bool isFinal) onResult,
    String localeId = 'en-US',
  }) async {
    if (!_ready) {
      await init();
      if (!_ready) return;
    }
    if (_listening) return;
    try {
      _listening = true;
      await _stt.listen(
        onResult: (r) {
          if (r.finalResult) {
            _listening = false;
          }
          onResult(r.recognizedWords, r.finalResult);
        },
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        localeId: localeId,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
      );
    } catch (e) {
      _listening = false;
      debugPrint('[Mic] startListen failed: $e');
    }
  }

  Future<void> stop() async {
    if (!_listening) return;
    try {
      await _stt.stop();
    } catch (e) {
      debugPrint('[Mic] stop failed: $e');
    } finally {
      _listening = false;
    }
  }

  /// List available locales — call to find ar-EG / ar-SA etc.
  Future<List<LocaleName>> locales() async {
    if (!_ready) return const [];
    try {
      return await _stt.locales();
    } catch (_) {
      return const [];
    }
  }
}
