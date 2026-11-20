import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'speech_text_corrector.dart';

/// Selectable Android speech input: the system recognizer or fully offline Vosk.
class MicService {
  MicService._();
  static final MicService instance = MicService._();

  static const _methodChannel = MethodChannel('spectrulenpor/vosk');
  static const _eventChannel = EventChannel('spectrulenpor/vosk/events');
  static const _englishModel = 'vosk-model-small-en-us-0.15';
  static const _arabicModel = 'vosk-model-ar-mgb2-0.4';
  static const _englishUrl =
      'https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip';
  static const _arabicUrl =
      'https://alphacephei.com/vosk/models/vosk-model-ar-mgb2-0.4.zip';

  final SpeechToText _stt = SpeechToText();
  StreamSubscription<dynamic>? _voskEvents;
  void Function(String text, bool isFinal)? _voskOnResult;
  String _voskCommitted = '';

  bool _ready = false;
  bool _listening = false;
  String _engine = 'system';
  String? _modelPath;
  String? _activeLanguage;

  bool get isReady => _ready;
  bool get isListening => _listening;
  String get engine => _engine;
  String? get modelPath => _modelPath;
  String? get activeLanguage => _activeLanguage;

  String? lastError;
  String? statusMessage;
  double? downloadProgress;
  PermissionStatus permissionStatus = PermissionStatus.denied;

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('stt_engine');
    if (saved == 'vosk' || saved == 'system') _engine = saved!;
  }

  Future<void> setEngine(String value) async {
    if (value != 'system' && value != 'vosk') {
      throw ArgumentError.value(value, 'value', 'Unknown speech engine.');
    }
    if (_listening) await stop();
    _engine = value;
    _ready = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('stt_engine', value);
    lastError = null;
    statusMessage = value == 'vosk'
        ? 'Offline Vosk selected. The language model is installed on first use.'
        : 'System speech recognition selected.';
  }

  Future<bool> ensurePermission() async {
    try {
      permissionStatus = await Permission.microphone.status;
      if (permissionStatus.isGranted) return true;
      permissionStatus = await Permission.microphone.request();
      if (!permissionStatus.isGranted) {
        lastError = permissionStatus.isPermanentlyDenied
            ? 'Microphone permission is permanently denied. Enable it in App settings.'
            : 'Microphone permission was not granted.';
      }
      return permissionStatus.isGranted;
    } catch (error) {
      lastError = 'Microphone permission check failed: $error';
      debugPrint('[Mic] $lastError');
      return false;
    }
  }

  Future<void> init() async {
    await loadSettings();
    if (_engine == 'vosk') {
      _ready = true;
      _subscribeVoskEvents();
      return;
    }
    if (_ready) return;
    try {
      _ready = await _stt.initialize(
        onError: (error) {
          _listening = false;
          lastError = error.errorMsg;
          debugPrint('[Mic] recognition error: ${error.errorMsg}');
        },
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            _listening = false;
          }
          debugPrint('[Mic] status: $status');
        },
      );
      if (!_ready)
        lastError ??= 'No Android speech recognition service is available.';
    } on MissingPluginException {
      lastError = 'Speech recognition is unavailable on this platform.';
      _ready = false;
    } catch (error) {
      lastError = 'Speech recognizer initialization failed: $error';
      debugPrint('[Mic] $lastError');
      _ready = false;
    }
  }

  void _subscribeVoskEvents() {
    _voskEvents ??= _eventChannel.receiveBroadcastStream().listen(
      _handleVoskEvent,
      onError: (Object error) {
        lastError = 'Offline speech engine error: $error';
        _listening = false;
        debugPrint('[Mic] $lastError');
      },
    );
  }

  void _handleVoskEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type']?.toString() ?? '';
    final payload = event['payload'];
    if (type == 'download' && payload is Map) {
      final received = (payload['received'] as num?)?.toInt() ?? 0;
      final total = (payload['total'] as num?)?.toInt() ?? 0;
      downloadProgress = total > 0 ? received / total : null;
      statusMessage = total > 0
          ? 'Downloading offline model: ${(downloadProgress! * 100).round()}%'
          : 'Downloading offline speech model…';
      return;
    }
    if (type == 'modelReady') {
      downloadProgress = 1;
      statusMessage = 'Offline speech model installed.';
      return;
    }
    if (type == 'error') {
      lastError = payload?.toString() ?? 'Offline speech recognition failed.';
      _listening = false;
      return;
    }
    if (type == 'timeout') {
      _listening = false;
      _emitVoskResult(_voskCommitted, true);
      _voskCommitted = '';
      return;
    }
    if (type != 'partial' && type != 'result' && type != 'final') return;

    final decoded = _decodeHypothesis(payload);
    final language = _activeLanguage ?? 'en';
    if (type == 'partial') {
      if (decoded.isEmpty) return;
      final partial = SpeechTextCorrector.correct(
        decoded,
        languageCode: language,
      );
      _emitVoskResult(
        [_voskCommitted, partial].where((part) => part.isNotEmpty).join(' '),
        false,
      );
      return;
    }

    final phrase = SpeechTextCorrector.correct(
      decoded,
      languageCode: language,
      isFinal: true,
    );
    if (phrase.isNotEmpty) {
      _voskCommitted =
          [_voskCommitted, phrase].where((part) => part.isNotEmpty).join(' ');
    }
    if (type == 'result') {
      _emitVoskResult(_voskCommitted, false);
      return;
    }

    _listening = false;
    _emitVoskResult(_voskCommitted, true);
    _voskCommitted = '';
  }

  String _decodeHypothesis(dynamic payload) {
    if (payload is Map) {
      return (payload['text'] ?? payload['partial'] ?? '').toString();
    }
    if (payload is! String) return '';
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map)
        return (decoded['text'] ?? decoded['partial'] ?? '').toString();
    } catch (_) {
      return payload;
    }
    return '';
  }

  void _emitVoskResult(String text, bool isFinal) {
    _voskOnResult?.call(text, isFinal);
  }

  Future<String> _ensureVoskModel(String localeId) async {
    _subscribeVoskEvents();
    final language = localeId.toLowerCase().startsWith('ar') ? 'ar' : 'en';
    final name = language == 'ar' ? _arabicModel : _englishModel;
    final url = language == 'ar' ? _arabicUrl : _englishUrl;
    statusMessage = 'Checking offline speech model…';
    final previousPath = _modelPath;
    final previousLanguage = _activeLanguage;
    final path = await _methodChannel.invokeMethod<String>('ensureModel', {
      'modelName': name,
      'url': url,
    });
    if (path == null || path.isEmpty) {
      throw StateError('Vosk did not return an installed model path.');
    }
    if (previousPath != path || previousLanguage != language) {
      await _methodChannel.invokeMethod<bool>('loadModel', {'path': path});
    }
    _modelPath = path;
    _activeLanguage = language;
    statusMessage = language == 'ar'
        ? 'Arabic offline speech model ready.'
        : 'English offline speech model ready.';
    downloadProgress = 1;
    return path;
  }

  /// Installs the selected language pack before recording, useful from Settings.
  Future<bool> prepareOfflineModel({String localeId = 'en-US'}) async {
    try {
      await _ensureVoskModel(localeId);
      lastError = null;
      return true;
    } catch (error) {
      lastError = 'Could not install offline speech model: $error';
      statusMessage = lastError;
      debugPrint('[Mic] $lastError');
      return false;
    }
  }

  Future<String> _resolveLocale(String requested) async {
    final available = await locales();
    if (available.isEmpty) return requested;
    String normalize(String value) => value.replaceAll('_', '-').toLowerCase();
    final target = normalize(requested);
    for (final locale in available) {
      if (normalize(locale.localeId) == target) return locale.localeId;
    }
    final language = target.split('-').first;
    for (final locale in available) {
      if (normalize(locale.localeId).split('-').first == language) {
        return locale.localeId;
      }
    }
    return requested;
  }

  Future<bool> startListen({
    required void Function(String text, bool isFinal) onResult,
    String localeId = 'en-US',
  }) async {
    await init();
    if (!await ensurePermission()) return false;
    if (_listening) return true;
    lastError = null;
    _voskCommitted = '';
    _voskOnResult = onResult;

    if (_engine == 'vosk') {
      try {
        await _ensureVoskModel(localeId);
        await _methodChannel.invokeMethod<bool>('start');
        _listening = true;
        return true;
      } on PlatformException catch (error) {
        _listening = false;
        lastError = error.message ?? 'Could not start offline recognition.';
        debugPrint('[Mic] $lastError');
        return false;
      } catch (error) {
        _listening = false;
        lastError = 'Could not start offline recognition: $error';
        debugPrint('[Mic] $lastError');
        return false;
      }
    }

    if (!_ready) {
      lastError ??= 'System speech recognizer is not available on this device.';
      return false;
    }
    try {
      final resolvedLocale = await _resolveLocale(localeId);
      _listening = true;
      await _stt.listen(
        onResult: (result) {
          final corrected = SpeechTextCorrector.correct(
            result.recognizedWords,
            languageCode: localeId,
            isFinal: result.finalResult,
          );
          if (result.finalResult) _listening = false;
          onResult(corrected, result.finalResult);
        },
        listenOptions: SpeechListenOptions(
          listenFor: const Duration(seconds: 45),
          pauseFor: const Duration(seconds: 5),
          partialResults: true,
          localeId: resolvedLocale,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
        ),
      );
      return true;
    } catch (error) {
      _listening = false;
      lastError = 'Could not start speech recognition: $error';
      debugPrint('[Mic] $lastError');
      return false;
    }
  }

  Future<void> stop() async {
    if (_engine == 'vosk') {
      try {
        await _methodChannel.invokeMethod<bool>('stop');
      } catch (error) {
        lastError = 'Could not stop offline speech recognition: $error';
        debugPrint('[Mic] $lastError');
      }
      _listening = false;
      return;
    }
    if (!_listening) return;
    try {
      await _stt.stop();
    } catch (error) {
      lastError = 'Could not stop speech recognition: $error';
      debugPrint('[Mic] $lastError');
    } finally {
      _listening = false;
    }
  }

  Future<List<LocaleName>> locales() async {
    if (!_ready || _engine == 'vosk') return const [];
    try {
      return await _stt.locales();
    } catch (error) {
      debugPrint('[Mic] Could not list locales: $error');
      return const [];
    }
  }

  Future<void> dispose() async {
    await stop();
    await _voskEvents?.cancel();
    _voskEvents = null;
  }
}
