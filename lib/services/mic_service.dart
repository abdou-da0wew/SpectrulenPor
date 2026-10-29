import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:permission_handler/permission_handler.dart';
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

  /// Last failure reason (permission, unavailable engine, listen error) so
  /// the UI can surface it instead of failing silently.
  String? lastError;
  PermissionStatus permissionStatus = PermissionStatus.denied;

  /// RECORD_AUDIO is a runtime permission — [startListen] must not proceed
  /// until it is granted or recognition fails with ERROR_INSUFFICIENT_PERMISSIONS.
  Future<bool> ensurePermission() async {
    if (permissionStatus.isGranted) return true;
    try {
      permissionStatus = await Permission.microphone.request();
      return permissionStatus.isGranted;
    } on MissingPluginException {
      return true;
    } catch (e) {
      lastError = 'permission check failed: $e';
      debugPrint('[Mic] $lastError');
      return false;
    }
  }

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
      lastError = 'speech recognition plugin unavailable on this platform';
      _ready = false;
    } catch (e) {
      debugPrint('[Mic] init failed: $e');
      lastError = 'init failed: $e';
      _ready = false;
    }
  }

  /// Start listening. Calls [onResult] with the recognized text (partial +
  /// final). Automatically resets [isListening] when recognition finishes.
  ///
  /// Returns false when the mic could not start — check [lastError].
  Future<bool> startListen({
    required void Function(String text, bool isFinal) onResult,
    String localeId = 'en-US',
  }) async {
    if (!_ready) {
      await init();
    }
    if (!_ready) {
      lastError ??= 'speech recognizer not available on this device';
      return false;
    }
    if (!await ensurePermission()) {
      lastError ??= 'microphone permission was not granted';
      return false;
    }
    if (_listening) return true;
    try {
      _listening = true;
      lastError = null;
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
      return true;
    } catch (e) {
      _listening = false;
      lastError = 'listen failed: $e';
      debugPrint('[Mic] startListen failed: $e');
      return false;
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
