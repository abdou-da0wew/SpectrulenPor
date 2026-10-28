import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/bluetooth_status.dart';
import '../models/citation.dart';
import '../models/frame_data.dart';
import '../models/spectrum_reading.dart';
import '../services/bluetooth_camera_service.dart';
import '../services/chat_session.dart';
import '../services/docs_search_service.dart';
import '../services/flashlight_service.dart';
import '../services/internal_db_service.dart';
import '../services/local_vision_service.dart';
import '../services/mic_service.dart';
import '../services/moondream_service.dart';
import '../services/native_tts_service.dart';
import '../services/openrouter_service.dart';
import '../services/openrouter_tts_service.dart';
import '../services/phone_camera_service.dart';
import '../services/vision_gate.dart';
import '../services/yolo_detector.dart';
import 'bounding_box.dart';
import 'captured_frames.dart';

export '../models/bluetooth_status.dart';

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

/// Central observable state for SpectruLenPor.
class RecognitionState extends ChangeNotifier {
  final BluetoothCameraService bluetooth;
  final PhoneCameraService phoneCamera;
  final LocalVisionService vision;
  final OpenRouterService openRouter;
  final OpenRouterTtsService openRouterTts;
  final NativeTtsService nativeTts;
  final SharedPreferences prefs;
  final ValueChanged<String>? onLocaleChanged;

  StreamSubscription<BluetoothStatus>? _btStatusSub;
  StreamSubscription<FrameData>? _btFrameSub;
  StreamSubscription<FrameData>? _phoneFrameSub;
  StreamSubscription<SpectrumReading>? _btSensorSub;

  RecognitionState({
    required this.bluetooth,
    required this.phoneCamera,
    required this.vision,
    required this.openRouter,
    required this.openRouterTts,
    required this.nativeTts,
    required this.prefs,
    this.onLocaleChanged,
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
  int _upstreamStartModel = 0;
  String _localeCode = 'en';
  DocsSearchMode _searchMode = DocsSearchMode.semantic;

  bool get liveSpeak => _liveSpeak;
  bool get deepReasonEnabled => _deepReasonEnabled;
  bool get useOpenRouterTts => _useOpenRouterTts;
  bool get captureReasoningTokens => _captureReasoningTokens;
  int get fps => _fps;
  int get upstreamStartModel => _upstreamStartModel;
  String get localeCode => _localeCode;
  bool get isArabic => _localeCode.startsWith('ar');
  DocsSearchMode get searchMode => _searchMode;

  set searchMode(DocsSearchMode m) {
    _searchMode = m;
    prefs.setString('docs_search_mode', m.name);
    _chatSession?.searchMode = m;
    unawaited(InternalDatabaseService.instance.putUserData(
      'docs_search_mode',
      m.name,
      category: 'settings',
    ));
    notifyListeners();
  }

  set liveSpeak(bool v) {
    _liveSpeak = v;
    prefs.setBool('live_speak', v);
    if (!v) {
      nativeTts.stop();
      openRouterTts.stop();
    }
    notifyListeners();
  }

  set deepReasonEnabled(bool v) {
    _deepReasonEnabled = v;
    prefs.setBool('deep_reason', v);
    notifyListeners();
  }

  set useOpenRouterTts(bool v) {
    _useOpenRouterTts = v;
    prefs.setBool('use_or_tts', v);
    if (!v) openRouterTts.stop();
    notifyListeners();
  }

  set captureReasoningTokens(bool v) {
    _captureReasoningTokens = v;
    prefs.setBool('capture_reasoning', v);
    notifyListeners();
  }

  set fps(int v) {
    _fps = v.clamp(1, 4);
    prefs.setInt('fps', _fps);
    notifyListeners();
  }

  set upstreamStartModel(int v) {
    _upstreamStartModel = v.clamp(0, OpenRouterService.modelChain.length - 1);
    prefs.setInt('upstream_start_model', _upstreamStartModel);
    notifyListeners();
  }

  Future<void> setLocale(String code) async {
    _localeCode = code;
    await prefs.setString('locale', code);
    await nativeTts.setLanguage(code.startsWith('ar') ? 'ar-EG' : 'en-US');
    onLocaleChanged?.call(code);
    unawaited(InternalDatabaseService.instance.recordActivity(
      'locale_changed',
      target: code,
    ));
    notifyListeners();
  }

  void _loadSettings() {
    _cloudOnly = prefs.getBool('cloud_only') ?? false;
    _liveSpeak = prefs.getBool('live_speak') ?? true;
    _deepReasonEnabled = prefs.getBool('deep_reason') ?? true;
    _useOpenRouterTts = prefs.getBool('use_or_tts') ?? false;
    _captureReasoningTokens = prefs.getBool('capture_reasoning') ?? true;
    _fps = (prefs.getInt('fps') ?? 1).clamp(1, 4);
    _upstreamStartModel = (prefs.getInt('upstream_start_model') ?? 0)
        .clamp(0, OpenRouterService.modelChain.length - 1);
    _localeCode = prefs.getString('locale') ?? 'en';

    final savedMode = prefs.getString('docs_search_mode');
    if (savedMode != null) {
      _searchMode = DocsSearchMode.values.firstWhere(
        (m) => m.name == savedMode,
        orElse: () => DocsSearchMode.semantic,
      );
    }

    final mdKey = prefs.getString('moondream_api_key');
    if (mdKey != null) MoondreamService.instance.apiKey = mdKey;
    final llmKey = prefs.getString('openrouter_llm_key') ??
        prefs.getString('openrouter_api_key');
    if (llmKey != null) openRouter.apiKey = llmKey;
    final ttsKey = prefs.getString('openrouter_tts_key') ??
        prefs.getString('openrouter_api_key');
    if (ttsKey != null) openRouterTts.configure(apiKey: ttsKey);
  }

  // ----------------------------- Camera sources -----------------------------
  CameraSource _source = CameraSource.phone;
  CameraSource get source => _source;
  bool get usingPhoneCamera => _source == CameraSource.phone;

  PermissionStatus _cameraPermission = PermissionStatus.denied;
  PermissionStatus get cameraPermission => _cameraPermission;

  Future<void> requestCameraPermission() async {
    try {
      _cameraPermission = await Permission.camera.request();
      if (_cameraPermission.isGranted) {
        await startPhoneCamera();
      }
    } on MissingPluginException {
      debugPrint('[RecognitionState] permission_handler unavailable here.');
    } catch (e, st) {
      debugPrint('[RecognitionState] requestCameraPermission failed: $e');
      unawaited(InternalDatabaseService.instance.logError(
        'CameraPermission',
        'requestCameraPermission failed',
        error: e,
        stackTrace: st,
      ));
    }
    notifyListeners();
  }

  Future<void> checkCameraPermission() async {
    try {
      _cameraPermission = await Permission.camera.status;
      if (_cameraPermission.isGranted &&
          _source == CameraSource.phone &&
          !phoneCamera.isStreaming) {
        await startPhoneCamera();
      }
    } on MissingPluginException {
      // VM widget tests / unsupported host.
    } catch (e) {
      debugPrint('[RecognitionState] checkCameraPermission failed: $e');
    }
    notifyListeners();
  }

  Future<void> switchSource(CameraSource s) async {
    if (s == _source) return;
    _source = s;
    await phoneCamera.stop();
    if (s == CameraSource.phone) {
      await bluetooth.pauseStream();
      if (_cameraPermission.isGranted) {
        try {
          await phoneCamera.start();
        } catch (e) {
          _lastLabel = 'Phone camera error: $e';
        }
      }
    } else {
      if (_btStatus == BluetoothStatus.connected) {
        await bluetooth.resumeStream();
      }
    }
    unawaited(InternalDatabaseService.instance.recordActivity(
      'camera_source_switch',
      target: s.name,
    ));
    notifyListeners();
  }

  Future<void> startPhoneCamera() async {
    if (_source == CameraSource.phone && !phoneCamera.isStreaming) {
      try {
        await phoneCamera.start();
      } catch (e, st) {
        _lastLabel = 'Phone camera error: $e';
        unawaited(InternalDatabaseService.instance.logError(
          'PhoneCamera',
          'startPhoneCamera failed',
          error: e,
          stackTrace: st,
        ));
      }
      notifyListeners();
    }
  }

  Future<void> connectToGlasses() async {
    try {
      await bluetooth.scanAndConnect();
    } catch (e, st) {
      _lastLabel = 'Bluetooth error: $e';
      unawaited(InternalDatabaseService.instance.logError(
        'Bluetooth',
        'connectToGlasses failed',
        error: e,
        stackTrace: st,
      ));
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    await bluetooth.disconnect();
  }

  Future<void> setFlashlight(bool on) async {
    _autoFlashOn = false;
    _flashOn = on;
    if (_source == CameraSource.glasses) {
      await bluetooth.setFlashlight(on);
    } else {
      await FlashlightService.instance.setTorch(on);
    }
    notifyListeners();
  }

  bool _flashOn = false;
  bool get flashOn => _flashOn;

  // ----------------------------- YOLO + Selection + Chat -----------------------------
  final YoloDetector _yolo = YoloDetector.instance;
  final MicService _mic = MicService.instance;
  YoloDetector get yolo => _yolo;
  MicService get mic => _mic;

  List<BoundingBox> _currentBoxes = const [];
  List<BoundingBox> get currentBoxes => _currentBoxes;

  BoundingBox? _selectedBox;
  BoundingBox? get selectedBox => _selectedBox;

  bool _hasUnanalyzedSelection = false;
  bool get hasUnanalyzedSelection => _hasUnanalyzedSelection;

  bool _isAnalyzingSelected = false;
  bool get isAnalyzingSelected => _isAnalyzingSelected;

  String _analyzingStage = '';
  String get analyzingStage => _analyzingStage;

  CapturedFrames? _capturedFrames;
  CapturedFrames? get capturedFrames => _capturedFrames;

  MoondreamStructuredAnalysis? _moondreamAnalysis;
  MoondreamStructuredAnalysis? get moondreamAnalysis => _moondreamAnalysis;

  String? _firstLlmContext;
  String? get firstLlmContext => _firstLlmContext;

  AnnotatedMessage? _firstLlmAnnotated;
  AnnotatedMessage? get firstLlmAnnotated => _firstLlmAnnotated;

  List<Citation> _lastChatCitations = const [];
  List<Citation> get lastChatCitations => _lastChatCitations;

  ChatSession? _chatSession;
  ChatSession? get chatSession => _chatSession;

  /// "Cloud-only models (except YOLO26-Nano)":
  ///   * `true`  -> YOLO26-Nano stays local on-device, while VLM/LLM/TTS use
  ///                ONLY cloud models (Moondream3 Cloud + OpenRouter Cloud +
  ///                Fish-Audio Cloud TTS when configured), skipping non-YOLO
  ///                local fallbacks (local GGUF, ONNX classifier, ML Kit).
  ///   * `false` -> Full hybrid cascade with local offline fallbacks enabled.
  bool _cloudOnly = false;
  bool get cloudOnly => _cloudOnly;
  set cloudOnly(bool v) {
    _cloudOnly = v;
    prefs.setBool('cloud_only', v);
    unawaited(InternalDatabaseService.instance.recordActivity(
      'settings_changed',
      target: 'cloud_only',
      details: {'enabled': v},
    ));
    notifyListeners();
  }

  // ---------------------- AUTO-FLASHLIGHT ----------------------
  bool _autoFlashOn = false;
  bool get autoFlashOn => _autoFlashOn;

  VisionGateResult? _lastGate;
  VisionGateResult? get lastGate => _lastGate;

  bool get lastFrameTooDark =>
      _lastGate != null && _lastGate!.tooDark && !_lastGate!.blocked;

  void _wireSources() {
    _btStatusSub = bluetooth.statusStream.listen((s) {
      _btStatus = s;
      notifyListeners();
    });
    _btFrameSub = bluetooth.frameStream.listen((frame) {
      if (_source == CameraSource.glasses) {
        _onFrame(frame);
      }
    });
    _phoneFrameSub = phoneCamera.frameStream.listen((frame) {
      if (_source == CameraSource.phone) {
        _onFrame(frame);
      }
    });
    _btSensorSub = bluetooth.sensorStream.listen(_onSensor);
  }

  DateTime? _lastSensorLogAt;
  void _onSensor(SpectrumReading reading) {
    _lastReading = reading;
    if (reading.anyHazard && !_hazardActive) {
      _announceHazard('Sensor threshold exceeded (UV/IR).');
    }
    final now = DateTime.now();
    if (_lastSensorLogAt == null ||
        now.difference(_lastSensorLogAt!).inSeconds >= 5 ||
        reading.anyHazard) {
      _lastSensorLogAt = now;
      unawaited(InternalDatabaseService.instance.recordTelemetry(
        channel: 'ble_spectrum',
        reading: reading,
        hazard: reading.anyHazard,
      ));
    }
    notifyListeners();
  }

  // ----------------------------- Bluetooth & Sensors -----------------------------
  BluetoothStatus _btStatus = BluetoothStatus.disconnected;
  BluetoothStatus get btStatus => _btStatus;

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
    _runGatedPipeline(frame);
  }

  Future<void> _runGatedPipeline(FrameData frame) async {
    try {
      final gate = await VisionGate.check(frame.jpegBytes);
      _lastGate = gate;
      notifyListeners();

      if (gate.tooDark &&
          !gate.blocked &&
          _source == CameraSource.phone &&
          !_flashOn) {
        final ok = await phoneCamera.setTorch(true);
        if (ok) {
          _autoFlashOn = true;
          _flashOn = true;
          notifyListeners();
        }
        return;
      }

      if (_autoFlashOn && !gate.tooDark && _flashOn) {
        await phoneCamera.setTorch(false);
        _autoFlashOn = false;
        _flashOn = false;
        notifyListeners();
      }

      if (!gate.visible) {
        _visionSource = VisionSource.idle;
        notifyListeners();
        return;
      }

      // Live local YOLO26-Nano detection ONLY — dual JPEG capture & cloud VLM/LLM
      // strictly happen ONLY when the user selects a box and presses Capture & Analyze.
      await _runYoloDetection(frame);
    } catch (e, st) {
      _visionSource = VisionSource.error;
      debugPrint('[RecognitionState] gated pipeline error: $e');
      unawaited(InternalDatabaseService.instance.logError(
        'VisionPipeline',
        'Gated pipeline failed',
        error: e,
        stackTrace: st,
      ));
      notifyListeners();
    }
  }

  Future<void> _runLocalVision(FrameData frame) async {
    try {
      final desc = await vision.describe(
        frame.jpegBytes,
        lang: _localeCode,
        cloudOnly: _cloudOnly,
      );
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
        _lastPredictions = vision.lastTopK
            .map((p) => (p.label, p.confidence))
            .toList(growable: false);

        if (_liveSpeak) {
          if (_cloudOnly && openRouterTts.isConfigured) {
            await openRouterTts.speakMarkdown(desc);
          } else {
            await nativeTts.speak(desc);
          }
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

  int get lastChainIndex => openRouter.lastChainIndex;
  String get lastModelUsed => openRouter.lastModelUsed;
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
          _upstreamMs = firstTokenAt;
        }
        buffer.write(chunk);
        _deepReasoningMarkdown = buffer.toString();
        _upstreamStatus = UpstreamStatus.streaming;
        notifyListeners();

        final preferCloudTts =
            _useOpenRouterTts || (_cloudOnly && openRouterTts.isConfigured);
        if (_liveSpeak && !preferCloudTts) {
          await _speakCompletedSentences(buffer);
        }

        if (!_hazardActive && textSignalsHazard(buffer.toString())) {
          _announceHazard(localDescription);
        }
      }

      final st = matterStateFromText(_deepReasoningMarkdown);
      if (st != MatterState.unknown) {
        _matterState = st;
      }

      _upstreamStatus = UpstreamStatus.done;
      _upstreamMs = sw.elapsedMilliseconds;
      notifyListeners();

      final preferCloudTts =
          _useOpenRouterTts || (_cloudOnly && openRouterTts.isConfigured);
      if (_liveSpeak && preferCloudTts) {
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

  int _spokenUpTo = 0;
  Future<void> _speakCompletedSentences(StringBuffer buffer) async {
    final text = buffer.toString();
    if (text.length <= _spokenUpTo) return;
    final pending = text.substring(_spokenUpTo);

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
    out = out.replaceAll(
      RegExp(
        r'(?:```(?:\w+)?\s*)?<context_update>[\s\S]*?</context_update>(?:\s*```)?',
      ),
      ' ',
    );
    out = out.replaceAll(RegExp(r'\[VERIFIED\s+\d+\]'), '');
    out = out.replaceAll('[UNVERIFIED]', '');
    out = out.replaceAll(RegExp(r'\[\d+\]'), '');
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
      final msg = isArabic
          ? 'تحذير! تم اكتشاف مادة خطرة. تراجع بحذر.'
          : 'Warning! Hazardous material detected. Step back carefully.';
      if (_cloudOnly && openRouterTts.isConfigured) {
        unawaited(openRouterTts.speakMarkdown(msg));
      } else {
        unawaited(nativeTts.speak(msg));
      }
    }
    unawaited(InternalDatabaseService.instance.recordActivity(
      'hazard_triggered',
      target: about,
    ));
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
    _spokenUpTo = 0;
    await _runLocalVision(frame);
  }

  // ----------------------------- Test hooks -----------------------------
  @visibleForTesting
  void debugPushFrame(FrameData frame) => _onFrame(frame);

  @visibleForTesting
  void debugPushSensor(SpectrumReading reading) => _onSensor(reading);

  @visibleForTesting
  void debugSetBoxes(List<BoundingBox> boxes) {
    _currentBoxes = boxes;
    notifyListeners();
  }

  // ----------------------------- YOLO + Selection + Dual Capture -----------------------------

  Future<void> _runYoloDetection(FrameData frame) async {
    if (!_yolo.isReady) return;
    final boxes = await _yolo.detect(frame.jpegBytes);
    _currentBoxes = boxes;
    if (boxes.isNotEmpty && _lastLabel == null) {
      final top = boxes.first;
      final pct = (top.confidence * 100).round().clamp(0, 100);
      _lastLabel = isArabic
          ? 'تم رصد: ${top.label} ($pct%)'
          : 'Detected: ${top.label} ($pct%)';
    }
    notifyListeners();
  }

  /// User tapped a bounding box on the preview overlay — marks it as selected.
  void selectBox(BoundingBox? box) {
    _selectedBox = box;
    _hasUnanalyzedSelection = box != null;
    if (box != null) {
      unawaited(InternalDatabaseService.instance.recordActivity(
        'box_selected',
        target: box.label,
        details: {'confidence': box.confidence},
      ));
    }
    notifyListeners();
  }

  /// Strict user-gated dual capture + analysis:
  ///   * Requires BOTH a live frame AND a user-selected bounding box (`_selectedBox != null`).
  ///   * Captures two JPEGs ONLY when pressed:
  ///       1. `cleanJpeg`     — unobstructed camera frame
  ///       2. `withBoxesJpeg` — camera frame with the selected object marker painted on
  ///   * Runs Moondream3 Cloud `analyzeSelected` + OpenRouter grounded scientific
  ///     context writer + `FactCheckerService` + persists the anchored `ChatSession`
  ///     into `InternalDatabaseService`.
  Future<bool> captureAndAnalyzeSelected() async {
    if (_isAnalyzingSelected) return false;
    final frame = _lastFrame;
    final box = _selectedBox;
    if (frame == null || box == null) return false;

    final traceId = InternalDatabaseService.instance.startTraceId('analyze');
    _isAnalyzingSelected = true;
    _spokenUpTo = 0;
    _upstreamStatus = UpstreamStatus.waiting;
    _analyzingStage = isArabic
        ? 'جارٍ التقاط الصورتين والتحليل عبر موندريم…'
        : 'Capturing clean + marked frames & analyzing with Moondream AI…';
    notifyListeners();

    final sw = Stopwatch()..start();
    try {
      final cleanJpeg = frame.jpegBytes;
      final withBoxesJpeg = await InternalDatabaseService.instance.traceAsync(
        'image.paintSelectedMarker',
        () => _paintBoxesOnJpeg(cleanJpeg, _currentBoxes, box),
        traceId: traceId,
      );

      _capturedFrames = CapturedFrames(
        cleanJpeg: cleanJpeg,
        withBoxesJpeg: withBoxesJpeg,
        selectedBox: box,
        capturedAt: DateTime.now(),
      );
      notifyListeners();

      // Moondream3 Cloud is ALWAYS a cloud model — run whenever configured!
      if (MoondreamService.instance.isCloudConfigured) {
        _moondreamAnalysis = await InternalDatabaseService.instance.traceAsync(
          'moondream.analyzeSelected',
          () => MoondreamService.instance.analyzeSelected(
            cleanJpeg,
            withBoxesJpeg,
            selectedLabel: box.label,
            lang: _localeCode,
          ),
          traceId: traceId,
          attributes: {'label': box.label, 'cloudOnly': _cloudOnly},
        );
        if (_moondreamAnalysis != null) {
          _visionSource = VisionSource.moondreamCloud;
          final summaryLine = _moondreamAnalysis!.whatItIs.isNotEmpty
              ? _moondreamAnalysis!.whatItIs
              : _moondreamAnalysis!.caption;
          if (summaryLine.isNotEmpty) {
            _lastLabel = summaryLine;
          }
        }
      } else {
        _moondreamAnalysis = null;
      }

      _analyzingStage = isArabic
          ? 'جارٍ البحث في المراجع وإعداد السياق العلمي الموثق…'
          : 'Searching docs/Wiki/PubChem & writing grounded scientific context…';
      _upstreamStatus = UpstreamStatus.streaming;
      notifyListeners();

      final telemetry = _lastReading == null
          ? ''
          : '\n${_lastReading!.telemetryLine(_localeCode)}';
      final moondreamSummary = (_moondreamAnalysis?.toMergedSummary() ??
              'YOLO26-Nano detected selected object: ${box.label} '
                  '(confidence ${(box.confidence * 100).round()}%)') +
          telemetry;

      AnnotatedMessage annotated;
      try {
        annotated = await openRouter.writeScientificContextWithCitations(
          moondreamSummary: moondreamSummary,
          selectedLabel: box.label,
          lang: _localeCode,
          startModel: _upstreamStartModel,
          searchMode: _searchMode,
          traceId: traceId,
        );
      } catch (e, st) {
        unawaited(InternalDatabaseService.instance.logError(
          'OpenRouter',
          'writeScientificContextWithCitations failed',
          error: e,
          stackTrace: st,
        ));
        annotated = AnnotatedMessage(body: '(LLM context error: $e)');
      }

      _firstLlmAnnotated = annotated;
      _firstLlmContext = annotated.body;
      _lastChatCitations = annotated.citations;
      _deepReasoningMarkdown = annotated.body;
      _upstreamMs = sw.elapsedMilliseconds;
      _upstreamStatus = UpstreamStatus.done;

      final combinedText =
          '${_moondreamAnalysis?.toMergedSummary() ?? ''}\n${annotated.body}';
      final st = matterStateFromText(combinedText);
      if (st != MatterState.unknown) {
        _matterState = st;
      }
      if (!_hazardActive &&
          (_moondreamAnalysis?.hasHazard == true ||
              textSignalsHazard(annotated.body))) {
        _announceHazard(box.label);
      }

      _chatSession?.dispose();
      _chatSession = ChatSession(
        frames: _capturedFrames!,
        moondreamAnalysis: _moondreamAnalysis ??
            MoondreamStructuredAnalysis(
              caption: '',
              whatItIs: box.label,
              howItsUsed: '',
              whatsAround: '',
              visibleText: '',
              hazards: '',
              stateOfMatter: '',
            ),
        firstLlmContext: _firstLlmContext ?? '',
        openRouter: openRouter,
        initialCitations: annotated.citations,
        initialVerifiedCount: annotated.verifiedCount,
        initialUnverifiedCount: annotated.unverifiedCount,
        lang: _localeCode,
        searchMode: _searchMode,
      );

      _hasUnanalyzedSelection = false;
      _isAnalyzingSelected = false;
      _analyzingStage = '';
      unawaited(InternalDatabaseService.instance.recordActivity(
        'capture_analyze',
        target: box.label,
        details: {
          'sessionId': _chatSession!.sessionId,
          'durationMs': sw.elapsedMilliseconds,
          'citations': annotated.citations.length,
          'verified': annotated.verifiedCount,
          'cloudOnly': _cloudOnly,
        },
      ));
      notifyListeners();

      if (_liveSpeak && annotated.body.trim().isNotEmpty) {
        final preferCloudTts =
            _useOpenRouterTts || (_cloudOnly && openRouterTts.isConfigured);
        if (preferCloudTts) {
          unawaited(openRouterTts.speakMarkdown(annotated.body));
        } else if (!_cloudOnly) {
          unawaited(nativeTts.speak(_cleanForSpeech(annotated.body)));
        }
      }
      return true;
    } catch (e, st) {
      debugPrint('[RecognitionState] captureAndAnalyzeSelected error: $e');
      unawaited(InternalDatabaseService.instance.logError(
        'RecognitionState',
        'captureAndAnalyzeSelected failed',
        error: e,
        stackTrace: st,
      ));
      _upstreamStatus = UpstreamStatus.error;
      _isAnalyzingSelected = false;
      _analyzingStage = '';
      notifyListeners();
      return false;
    } finally {
      sw.stop();
    }
  }

  /// Hydrates a saved session from [InternalDatabaseService] as the active
  /// [chatSession] so the user can view and continue past conversations.
  Future<bool> resumeSavedChatSession(String sessionId) async {
    final record =
        await InternalDatabaseService.instance.loadChatSession(sessionId);
    if (record == null) return false;

    _capturedFrames = record.frames;
    _selectedBox = record.summary.selectedBox;
    _hasUnanalyzedSelection = false;
    _moondreamAnalysis = record.summary.moondreamAnalysis;
    _firstLlmContext = record.summary.firstLlmContext;

    _chatSession?.dispose();
    _chatSession = ChatSession.fromHydrated(
      record: record,
      openRouter: openRouter,
      searchMode: _searchMode,
    );
    unawaited(InternalDatabaseService.instance.recordActivity(
      'chat_session_resumed',
      target: record.summary.title,
      details: {'sessionId': sessionId},
    ));
    notifyListeners();
    return true;
  }

  Future<void> recaptureFromChat() async {
    final frame = _lastFrame;
    if (frame == null || _chatSession == null) return;
    final boxes =
        _yolo.isReady ? await _yolo.detect(frame.jpegBytes) : _currentBoxes;
    final newBox = boxes.isNotEmpty
        ? boxes.first
        : (_selectedBox ??
            const BoundingBox(
              x: 0.2,
              y: 0.2,
              w: 0.6,
              h: 0.6,
              label: 'sample',
              confidence: 1.0,
            ));
    _selectedBox = newBox;
    final withBoxes = await _paintBoxesOnJpeg(frame.jpegBytes, boxes, newBox);
    final newFrames = CapturedFrames(
      cleanJpeg: frame.jpegBytes,
      withBoxesJpeg: withBoxes,
      selectedBox: newBox,
      capturedAt: DateTime.now(),
    );
    _capturedFrames = newFrames;
    final newAnalysis = await _chatSession!.recapture(
      newFrames.cleanJpeg,
      newFrames.withBoxesJpeg,
      selectedLabel: newBox.label,
      lang: _localeCode,
    );
    if (newAnalysis != null) {
      _moondreamAnalysis = newAnalysis;
    }
    notifyListeners();
  }

  Future<Uint8List> _paintBoxesOnJpeg(
    Uint8List jpeg,
    List<BoundingBox> boxes,
    BoundingBox selected,
  ) async {
    return compute(
      _paintBoxesIsolate,
      _PaintBoxesArgs(jpeg, boxes, selected),
    );
  }

  Future<void> initV5Services() async {
    await InternalDatabaseService.instance.init();
    await _yolo.init();
    await _mic.init();
    await DocsSearchService.instance.init();
    notifyListeners();
  }

  @override
  void dispose() {
    _btStatusSub?.cancel();
    _btFrameSub?.cancel();
    _phoneFrameSub?.cancel();
    _btSensorSub?.cancel();
    _chatSession?.dispose();
    super.dispose();
  }
}

class _PaintBoxesArgs {
  final Uint8List jpeg;
  final List<BoundingBox> boxes;
  final BoundingBox selected;
  const _PaintBoxesArgs(this.jpeg, this.boxes, this.selected);
}

/// Paints the "with-boxes" JPEG variant:
///   * Unselected boxes get a subtle dusty-lavender outline for scene context.
///   * The user-selected box gets a prominent dusty-mauve double border, bold
///     corner target brackets, a center target crosshair reticle, and a crisp
///     white-on-mauve `SELECTED: <label> <pct>%` marker banner.
Uint8List _paintBoxesIsolate(_PaintBoxesArgs args) {
  try {
    final decoded = img.decodeImage(args.jpeg);
    if (decoded == null) return args.jpeg;
    final w = decoded.width;
    final h = decoded.height;
    if (w < 8 || h < 8) return args.jpeg;

    final allBoxes =
        args.boxes.isEmpty ? <BoundingBox>[args.selected] : args.boxes;

    final lavender = img.ColorRgba8(0x82, 0x53, 0x76, 0xCC);
    final mauve = img.ColorRgba8(0xA6, 0x7E, 0x98, 0xFF);
    final white = img.ColorRgba8(0xFF, 0xFF, 0xFF, 0xFF);

    for (final b in allBoxes) {
      final isSel = b.x == args.selected.x &&
          b.y == args.selected.y &&
          b.w == args.selected.w &&
          b.h == args.selected.h;
      final x1 = (b.x * w).round().clamp(0, w - 1);
      final y1 = (b.y * h).round().clamp(0, h - 1);
      final x2 = ((b.x + b.w) * w).round().clamp(0, w - 1);
      final y2 = ((b.y + b.h) * h).round().clamp(0, h - 1);
      if (x2 <= x1 + 2 || y2 <= y1 + 2) continue;

      if (!isSel) {
        img.drawRect(
          decoded,
          x1: x1,
          y1: y1,
          x2: x2,
          y2: y2,
          color: lavender,
          thickness: 2,
        );
        continue;
      }

      // Outer + inner frame for selected object
      img.drawRect(
        decoded,
        x1: x1,
        y1: y1,
        x2: x2,
        y2: y2,
        color: mauve,
        thickness: 5,
      );
      final inset = 4;
      if (x2 - x1 > inset * 2 && y2 - y1 > inset * 2) {
        img.drawRect(
          decoded,
          x1: x1 + inset,
          y1: y1 + inset,
          x2: x2 - inset,
          y2: y2 - inset,
          color: white,
          thickness: 2,
        );
      }

      // Corner target brackets
      final minSide = (x2 - x1) < (y2 - y1) ? (x2 - x1) : (y2 - y1);
      final bracket = (minSide * 0.22).round().clamp(8, 42);
      img.drawLine(decoded, x1: x1, y1: y1, x2: x1 + bracket, y2: y1, color: white, thickness: 4);
      img.drawLine(decoded, x1: x1, y1: y1, x2: x1, y2: y1 + bracket, color: white, thickness: 4);
      img.drawLine(decoded, x1: x2, y1: y1, x2: x2 - bracket, y2: y1, color: white, thickness: 4);
      img.drawLine(decoded, x1: x2, y1: y1, x2: x2, y2: y1 + bracket, color: white, thickness: 4);
      img.drawLine(decoded, x1: x1, y1: y2, x2: x1 + bracket, y2: y2, color: white, thickness: 4);
      img.drawLine(decoded, x1: x1, y1: y2, x2: x1, y2: y2 - bracket, color: white, thickness: 4);
      img.drawLine(decoded, x1: x2, y1: y2, x2: x2 - bracket, y2: y2, color: white, thickness: 4);
      img.drawLine(decoded, x1: x2, y1: y2, x2: x2, y2: y2 - bracket, color: white, thickness: 4);

      // Center target marker reticle
      final cx = ((x1 + x2) ~/ 2).clamp(0, w - 1);
      final cy = ((y1 + y2) ~/ 2).clamp(0, h - 1);
      final rad = (minSide * 0.08).round().clamp(6, 18);
      img.drawCircle(decoded, x: cx, y: cy, radius: rad, color: mauve);
      img.drawLine(
        decoded,
        x1: (cx - rad - 6).clamp(0, w - 1),
        y1: cy,
        x2: (cx + rad + 6).clamp(0, w - 1),
        y2: cy,
        color: white,
        thickness: 2,
      );
      img.drawLine(
        decoded,
        x1: cx,
        y1: (cy - rad - 6).clamp(0, h - 1),
        x2: cx,
        y2: (cy + rad + 6).clamp(0, h - 1),
        color: white,
        thickness: 2,
      );

      // Readable SELECTED label banner
      final pct = (b.confidence * 100).round().clamp(0, 100);
      final tagText = 'SELECTED: ${b.label.toUpperCase()} ($pct%)';
      final bannerH = 24;
      final bannerW = (tagText.length * 9 + 16).clamp(80, w);
      final bx1 = x1.clamp(0, (w - bannerW).clamp(0, w));
      final by1 = (y1 >= bannerH + 2)
          ? (y1 - bannerH)
          : y1.clamp(0, (h - bannerH).clamp(0, h));
      img.fillRect(
        decoded,
        x1: bx1,
        y1: by1,
        x2: (bx1 + bannerW).clamp(0, w),
        y2: (by1 + bannerH).clamp(0, h),
        color: mauve,
      );
      img.drawString(
        decoded,
        tagText,
        font: img.arial14,
        x: bx1 + 6,
        y: by1 + 5,
        color: white,
      );
    }
    return Uint8List.fromList(img.encodeJpg(decoded, quality: 90));
  } catch (e) {
    debugPrint('[_paintBoxesOnJpeg] failed: $e');
    return args.jpeg;
  }
}
