import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/frame_data.dart';
import '../models/spectrum_reading.dart';
import '../services/bluetooth_camera_service.dart';
import '../services/local_vision_service.dart';
import '../services/moondream_service.dart';
import '../services/native_tts_service.dart';
import '../services/openrouter_service.dart';
import '../services/openrouter_tts_service.dart';
import '../services/phone_camera_service.dart';

/// Connection state of the BLE camera.
enum BluetoothStatus { disconnected, scanning, connecting, connected, error }

/// Where the current description came from.
enum VisionSource {
  idle,
  moondreamCloud, // moondream3.1-9B-A2B via api.moondream.ai (PRIMARY)
  moondreamLocal, // GGUF via platform channel (offline fallback)
  onnx, // specialized quantized classifier (offline)
  mlkit, // ML Kit labeling + OCR (last resort)
  error,
}

/// What the OpenRouter upstream tier is doing right now.
enum UpstreamStatus { idle, waiting, streaming, done, error }

/// Which camera feeds the pipeline.
enum CameraSource { phone, glasses }

/// Central observable state for the whole app.
///
/// Pipeline (v3 — Moondream3-cloud-first):
///   phone camera / ESP32-CAM BLE frames
///     → throttle (1-4 fps)
///     → Moondream3 cloud caption (local Moondream → ONNX → ML Kit offline)
///     → instant spoken label (native TTS, ~0 extra latency)
///     → OpenRouter presenter (gemma → inkling → nemotron chain)
///     → streamed fish-audio TTS (or per-sentence native TTS)
///     → hazard engine (UV/IR thresholds + bilingual keywords)
class RecognitionState extends ChangeNotifier {
  final BluetoothCameraService bluetooth;
  final PhoneCameraService phoneCamera;
  final LocalVisionService vision;
  final OpenRouterService openRouter;
  final OpenRouterTtsService openRouterTts;
  final NativeTtsService nativeTts;
  final SharedPreferences prefs;

  RecognitionState({
    required this.bluetooth,
    required this.phoneCamera,
    required this.vision,
    required this.openRouter,
    required this.openRouterTts,
    required this.nativeTts,
    required this.prefs,
  }) {
    _wireSources();
    _loadSettings();
  }

  // ----------------------------- Settings -----------------------------
  bool _liveSpeak = true;
  bool _deepReasonEnabled = true;
  bool _useOpenRouterTts = false;
  bool _captureReasoningTokens = true;
  int _fps = 1;
  int _upstreamStartModel = 0; // index into OpenRouterService.modelChain
  String _localeCode = 'en';

  bool get liveSpeak => _liveSpeak;
  bool get deepReasonEnabled => _deepReasonEnabled;
  bool get useOpenRouterTts => _useOpenRouterTts;
  bool get captureReasoningTokens => _captureReasoningTokens;
  int get fps => _fps;
  int get upstreamStartModel => _upstreamStartModel;
  String get localeCode => _localeCode;
  bool get isArabic => _localeCode.startsWith('ar');

  set liveSpeak(bool v) { _liveSpeak = v; prefs.setBool('live_speak', v); notifyListeners(); }
  set deepReasonEnabled(bool v) { _deepReasonEnabled = v; prefs.setBool('deep_reason', v); notifyListeners(); }
  set useOpenRouterTts(bool v) {
    _useOpenRouterTts = v;
    prefs.setBool('use_or_tts', v);
    if (!v) openRouterTts.stop(); // switching back to native → kill stream
    notifyListeners();
  }
  set captureReasoningTokens(bool v) {
    _captureReasoningTokens = v;
    prefs.setBool('capture_reasoning', v);
    notifyListeners();
  }
  set fps(int v) { _fps = v.clamp(1, 4); prefs.setInt('fps', _fps); notifyListeners(); }
  set upstreamStartModel(int v) {
    _upstreamStartModel = v.clamp(0, OpenRouterService.modelChain.length - 1);
    prefs.setInt('upstream_start_model', _upstreamStartModel);
    notifyListeners();
  }

  Future<void> setLocale(String code) async {
    _localeCode = code;
    await prefs.setString('locale', code);
    await nativeTts.setLanguage(code.startsWith('ar') ? 'ar-EG' : 'en-US');
    notifyListeners();
  }

  void _loadSettings() {
    _liveSpeak = prefs.getBool('live_speak') ?? true;
    _deepReasonEnabled = prefs.getBool('deep_reason') ?? true;
    _useOpenRouterTts = prefs.getBool('use_or_tts') ?? false;
    _captureReasoningTokens = prefs.getBool('capture_reasoning') ?? true;
    _fps = prefs.getInt('fps') ?? 1;
    _upstreamStartModel = prefs.getInt('upstream_start_model') ?? 0;
    _localeCode = prefs.getString('locale') ?? 'en';

    // Hot-configure the cloud tiers from stored keys.
    MoondreamService.instance.apiKey =
        prefs.getString('moondream_api_key') ?? '';
    openRouterTts.configure(
      apiKey: prefs.getString('openrouter_api_key') ?? '',
    );
  }

  // ----------------------------- Camera sources -----------------------------
  CameraSource _source = CameraSource.phone;

  CameraSource get source => _source;
  bool get usingPhoneCamera => _source == CameraSource.phone;

  Future<void> switchSource(CameraSource s) async {
    if (s == _source) return;
    _source = s;
    await phoneCamera.stop();
    if (s == CameraSource.phone) {
      await bluetooth.pauseStream();
      try {
        await phoneCamera.start();
      } catch (e) {
        _lastLabel = 'Phone camera error: $e';
      }
    } else {
      if (btStatus == BluetoothStatus.connected) {
        await bluetooth.resumeStream();
      }
    }
    notifyListeners();
  }

  Future<void> startPhoneCamera() async {
    if (_source == CameraSource.phone && !phoneCamera.isStreaming) {
      await phoneCamera.start();
      notifyListeners();
    }
  }

  Future<void> connectToGlasses() async {
    await bluetooth.scanAndConnect();
  }

  Future<void> disconnect() async {
    await bluetooth.disconnect();
  }

  Future<void> setFlashlight(bool on) async {
    _flashOn = on;
    if (_source == CameraSource.glasses) {
      await bluetooth.setFlashlight(on);
    } else {
      await phoneCamera.setTorch(on);
    }
    notifyListeners();
  }

  bool _flashOn = false;
  bool get flashOn => _flashOn;

  void _wireSources() {
    bluetooth.statusStream.listen((s) {
      _btStatus = s;
      notifyListeners();
    });
    bluetooth.frameStream.listen(_onFrame);
    phoneCamera.frameStream.listen(_onFrame);
    bluetooth.sensorStream.listen((reading) {
      _lastReading = reading;
      // Sensor-level hazard check (UV / IR thresholds).
      if (reading.anyHazard && !_hazardActive) {
        _announceHazard('Sensor threshold exceeded (UV/IR).');
      }
      notifyListeners();
    });
  }

  // ----------------------------- Bluetooth -----------------------------
  BluetoothStatus _btStatus = BluetoothStatus.disconnected;
  BluetoothStatus get btStatus => _btStatus;

  // ----------------------------- Sensors -----------------------------
  SpectrumReading? _lastReading;
  SpectrumReading? get lastReading => _lastReading;

  bool _hazardActive = false;
  bool get hazardActive => _hazardActive;
  String _hazardReason = '';
  String get hazardReason => _hazardReason;

  // ----------------------------- Frame handling -----------------------------
  FrameData? _lastFrame;
  FrameData? get lastFrame => _lastFrame;

  String? _lastLabel;
  String? get lastLabel => _lastLabel;

  List<(String, double)>? _lastPredictions;
  List<(String, double)>? get lastPredictions => _lastPredictions;

  VisionSource _visionSource = VisionSource.idle;
  VisionSource get visionSource => _visionSource;

  DateTime? _lastProcessAt;

  void _onFrame(FrameData frame) {
    _lastFrame = frame;
    notifyListeners();

    final throttleMs = 1000 ~/ _fps;
    final now = DateTime.now();
    if (_lastProcessAt != null &&
        now.difference(_lastProcessAt!).inMilliseconds < throttleMs) {
      return;
    }
    _lastProcessAt = now;
    _runLocalVision(frame);
  }

  Future<void> _runLocalVision(FrameData frame) async {
    try {
      final desc = await vision.describe(frame.jpegBytes, lang: _localeCode);
      _visionSource = switch (vision.lastEngine) {
        'moondream_cloud' => VisionSource.moondreamCloud,
        'moondream_local' => VisionSource.moondreamLocal,
        'onnx' => VisionSource.onnx,
        'mlkit' => VisionSource.mlkit,
        _ => VisionSource.idle,
      };

      if (desc == null || desc.isEmpty) {
        _lastLabel = null;
      } else {
        _lastLabel = desc;

        // Reuse the predictions cached by vision.describe() — no second
        // inference pass (latency).
        _lastPredictions = vision.lastTopK
            .map((p) => (p.label, p.confidence))
            .toList(growable: false);

        if (_liveSpeak) {
          await nativeTts.speak(desc);
        }

        if (_deepReasonEnabled) {
          unawaited(_runUpstream(desc));
        }
      }
    } catch (e) {
      _visionSource = VisionSource.error;
      _lastLabel = 'Vision error: $e';
    }
    notifyListeners();
  }

  // ----------------------------- Upstream -----------------------------
  UpstreamStatus _upstreamStatus = UpstreamStatus.idle;
  UpstreamStatus get upstreamStatus => _upstreamStatus;

  String _deepReasoningMarkdown = '';
  String get deepReasoningMarkdown => _deepReasoningMarkdown;

  int _upstreamMs = 0;
  int get upstreamMs => _upstreamMs;

  /// Which OpenRouter chain entry delivered the last analysis.
  int get lastChainIndex => openRouter.lastChainIndex;
  String get lastModelUsed => openRouter.lastModelUsed;

  /// Reasoning tokens captured from the final usage chunk (reasoning
  /// models only). Surfaced in the settings diagnostics.
  int? get reasoningTokens => openRouter.lastReasoningTokens;

  Future<void> _runUpstream(String localDescription) async {
    _upstreamStatus = UpstreamStatus.waiting;
    notifyListeners();

    final sw = Stopwatch()..start();
    var firstTokenAt = 0;

    try {
      final buffer = StringBuffer();
      final telemetry =
          _lastReading == null ? null : _lastReading!.telemetryLine(_localeCode);

      await for (final chunk in openRouter.streamAnalysis(
        labelSentence: localDescription,
        moondreamAnalysis: vision.lastCloudAnalysis,
        predictions: _lastPredictions,
        telemetry: telemetry,
        lang: _localeCode,
        startModel: _upstreamStartModel,
      )) {
        if (firstTokenAt == 0) {
          firstTokenAt = sw.elapsedMilliseconds;
          _upstreamMs = firstTokenAt; // time-to-first-token = latency metric
        }
        buffer.write(chunk);
        _deepReasoningMarkdown = buffer.toString();
        _upstreamStatus = UpstreamStatus.streaming;
        notifyListeners();

        // Low-latency speech: speak each completed sentence as it streams
        // (native engine only — fish-audio narrates the full reply at end).
        if (_liveSpeak && !_useOpenRouterTts) {
          await _speakCompletedSentences(buffer);
        }

        // Hazard keyword detection on the streaming text.
        if (!_hazardActive && textSignalsHazard(buffer.toString())) {
          _announceHazard(localDescription);
        }
      }

      // Matter state parse (solid / liquid / gas) from the final text.
      final st = matterStateFromText(_deepReasoningMarkdown);
      if (st != MatterState.unknown) {
        _matterState = st;
      }

      _upstreamStatus = UpstreamStatus.done;
      _upstreamMs = sw.elapsedMilliseconds;
      notifyListeners();

      // Streamed fish-audio narration of the finished reply.
      if (_liveSpeak && _useOpenRouterTts) {
        await openRouterTts.speakMarkdown(_deepReasoningMarkdown);
      }
    } catch (e) {
      _upstreamStatus = UpstreamStatus.error;
      _deepReasoningMarkdown = 'Upstream error: $e';
      notifyListeners();
    } finally {
      sw.stop();
    }
  }

  /// Speaks and drains any *complete* sentence waiting in the buffer.
  /// This is what brings first audio to ~1s: no waiting for the full reply.
  String _spokenUpTo = '';
  Future<void> _speakCompletedSentences(StringBuffer buffer) async {
    final text = buffer.toString();
    if (text.length <= _spokenUpTo.length) return;
    final pending = text.substring(_spokenUpTo.length);

    // Sentence terminators for EN + AR.
    final match = RegExp(r'[.!?؟][^.!?؟]*$').firstMatch(pending);
    if (match == null) return;

    final speakable = pending.substring(0, match.end).trim();
    _spokenUpTo = text.length - (pending.length - match.end);
    if (speakable.isNotEmpty) {
      await nativeTts.speak(_cleanForSpeech(speakable));
    }
  }

  String _cleanForSpeech(String s) {
    var out = s;
    out = out.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
    out = out.replaceAll(RegExp(r'[*_`#>\-]'), ' ');
    out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
    return out;
  }

  // ----------------------------- Hazard -----------------------------
  MatterState _matterState = MatterState.unknown;
  MatterState get matterState => _matterState;

  void _announceHazard(String about) {
    _hazardActive = true;
    _hazardReason = about;
    if (_liveSpeak) {
      // Native engine on purpose: hazard alerts must fire even offline and
      // cannot wait on a network TTS round-trip.
      nativeTts.speak(_localeCode.startsWith('ar')
          ? 'تحذير! تم اكتشاف مادة خطرة. تراجع بحذر.'
          : 'Warning! Hazardous material detected. Step back carefully.');
    }
    notifyListeners();
  }

  void clearHazard() {
    _hazardActive = false;
    _hazardReason = '';
    notifyListeners();
  }

  // ----------------------------- Manual trigger -----------------------------
  Future<void> captureAndAnalyzeNow() async {
    final frame = _lastFrame;
    if (frame == null) return;
    _spokenUpTo = '';
    await _runLocalVision(frame);
  }

  @override
  void dispose() {
    super.dispose();
  }
}
