import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/frame_data.dart';
import '../services/bluetooth_camera_service.dart';
import '../services/local_vision_service.dart';
import '../services/native_tts_service.dart';
import '../services/openrouter_service.dart';
import '../services/openrouter_tts_service.dart';

/// Connection state of the BLE camera.
enum BluetoothStatus { disconnected, scanning, connecting, connected, error }

/// Where the current description came from.
enum VisionSource { idle, mlkit, moondream, error }

/// What the OpenRouter upstream tier is doing right now.
enum UpstreamStatus { idle, waiting, streaming, done, error }

/// Central observable state for the whole app.
///
/// Subscribes to the BLE frame stream, throttles it to ~1 fps, runs local
/// vision, and forwards the textual description upstream for deep reasoning
/// + TTS. UI widgets watch this via Provider.
class RecognitionState extends ChangeNotifier {
  final BluetoothCameraService bluetooth;
  final LocalVisionService vision;
  final OpenRouterService openRouter;
  final OpenRouterTtsService openRouterTts;
  final NativeTtsService nativeTts;
  final SharedPreferences prefs;

  RecognitionState({
    required this.bluetooth,
    required this.vision,
    required this.openRouter,
    required this.openRouterTts,
    required this.nativeTts,
    required this.prefs,
  }) {
    _wireBluetooth();
    _settingsLoad();
  }

  // ----------------------------- Settings -----------------------------
  bool _liveSpeak = true;
  bool _deepReasonEnabled = true;
  bool _useOpenRouterTts = false; // default: native TTS for low latency
  int _fps = 1; // 1 fps default; user can raise to 2
  String _upstreamModel = 'google/gemini-2.5-flash:free';

  bool get liveSpeak => _liveSpeak;
  bool get deepReasonEnabled => _deepReasonEnabled;
  bool get useOpenRouterTts => _useOpenRouterTts;
  int get fps => _fps;
  String get upstreamModel => _upstreamModel;

  set liveSpeak(bool v) { _liveSpeak = v; prefs.setBool('live_speak', v); notifyListeners(); }
  set deepReasonEnabled(bool v) { _deepReasonEnabled = v; prefs.setBool('deep_reason', v); notifyListeners(); }
  set useOpenRouterTts(bool v) { _useOpenRouterTts = v; prefs.setBool('use_or_tts', v); notifyListeners(); }
  set fps(int v) { _fps = v.clamp(1, 4); prefs.setInt('fps', _fps); notifyListeners(); }
  set upstreamModel(String v) { _upstreamModel = v; prefs.setString('upstream_model', v); notifyListeners(); }

  void _settingsLoad() {
    _liveSpeak = prefs.getBool('live_speak') ?? true;
    _deepReasonEnabled = prefs.getBool('deep_reason') ?? true;
    _useOpenRouterTts = prefs.getBool('use_or_tts') ?? false;
    _fps = prefs.getInt('fps') ?? 1;
    _upstreamModel = prefs.getString('upstream_model') ?? _upstreamModel;
  }

  // ----------------------------- Bluetooth -----------------------------
  BluetoothStatus _btStatus = BluetoothStatus.disconnected;
  BluetoothStatus get btStatus => _btStatus;

  void _wireBluetooth() {
    bluetooth.statusStream.listen((s) {
      _btStatus = s;
      notifyListeners();
    });
    _frameSub = bluetooth.frameStream.listen(_onFrame);
  }

  Future<void> connectToGlasses() async {
    await bluetooth.scanAndConnect();
  }

  Future<void> disconnect() async {
    await bluetooth.disconnect();
  }

  // ----------------------------- Frame handling -----------------------------
  FrameData? _lastFrame;
  FrameData? get lastFrame => _lastFrame;

  String? _lastLabel;
  String? get lastLabel => _lastLabel;

  VisionSource _visionSource = VisionSource.idle;
  VisionSource get visionSource => _visionSource;

  StreamSubscription? _frameSub;
  DateTime? _lastProcessAt;

  void _onFrame(FrameData frame) {
    _lastFrame = frame;
    notifyListeners();

    final throttleMs = 1000 ~/ _fps;
    final now = DateTime.now();
    if (_lastProcessAt != null &&
        now.difference(_lastProcessAt!).inMilliseconds < throttleMs) {
      return; // throttled — keep the frame for UI preview but skip AI
    }
    _lastProcessAt = now;
    _runLocalVision(frame);
  }

  Future<void> _runLocalVision(FrameData frame) async {
    _visionSource = vision.useMoondream
        ? VisionSource.moondream
        : VisionSource.mlkit;
    notifyListeners();
    try {
      final label = await vision.describe(frame.jpegBytes);
      if (label == null || label.isEmpty) {
        _lastLabel = null;
        _visionSource = VisionSource.idle;
      } else {
        _lastLabel = label;
        if (_liveSpeak) {
          await nativeTts.speak(label); // instant narration on the live path
        }
        if (_deepReasonEnabled) {
          unawaited(_runUpstream(label));
        }
      }
    } catch (e) {
      _visionSource = VisionSource.error;
      _lastLabel = 'Vision error: $e';
    }
    notifyListeners();
  }

  // ----------------------------- Upstream (OpenRouter) -----------------------------
  UpstreamStatus _upstreamStatus = UpstreamStatus.idle;
  UpstreamStatus get upstreamStatus => _upstreamStatus;

  String _deepReasoningMarkdown = '';
  String get deepReasoningMarkdown => _deepReasoningMarkdown;

  Future<void> _runUpstream(String localDescription) async {
    _upstreamStatus = UpstreamStatus.waiting;
    notifyListeners();

    try {
      final buffer = StringBuffer();
      await for (final chunk in openRouter.streamDeepReasoning(
        model: _upstreamModel,
        localDescription: localDescription,
      )) {
        buffer.write(chunk);
        _deepReasoningMarkdown = buffer.toString();
        _upstreamStatus = UpstreamStatus.streaming;
        notifyListeners();
      }
      _upstreamStatus = UpstreamStatus.done;
      notifyListeners();

      // Speak the deep reasoning only if user enabled OpenRouter TTS,
      // otherwise re-narrate locally using the native TTS engine.
      if (_useOpenRouterTts) {
        await openRouterTts.speakMarkdown(_deepReasoningMarkdown, model: _upstreamModel);
      } else if (_liveSpeak) {
        await nativeTts.speak(_deepReasoningMarkdown);
      }
    } catch (e) {
      _upstreamStatus = UpstreamStatus.error;
      _deepReasoningMarkdown = 'Upstream error: $e';
      notifyListeners();
    }
  }

  /// Manual trigger: "describe + reason + speak what's in front of me right now"
  Future<void> captureAndAnalyzeNow() async {
    final frame = _lastFrame;
    if (frame == null) return;
    await _runLocalVision(frame);
  }

  @override
  void dispose() {
    _frameSub?.cancel();
    super.dispose();
  }
}
