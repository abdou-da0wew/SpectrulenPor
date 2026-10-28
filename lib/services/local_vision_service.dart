import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'flashlight_service.dart';
import 'moondream_service.dart';
import 'onnx_prediction.dart';
import 'onnx_vision_service.dart';
import 'vision_gate.dart';
import 'vision_mlkit.dart';

/// Cascade vision coordinator — turns a raw JPEG frame into a short, truthful
/// factual description for the user AND for the upstream LLM presenter.
///
/// Priority order:
///   0. **VisionGate**        — brightness + texture check
///   1. **Moondream3 Cloud**  — `moondream3.1-9B-A2B` at api.moondream.ai (PRIMARY)
///   2. **Local Moondream**   — on-device GGUF via `com.spectraglass/llama` (skipped when `cloudOnly`)
///   3. **ONNX Runtime**      — optional local quantized classifier (skipped when `cloudOnly`)
///   4. **Google ML Kit**     — image labeling + OCR fallback (skipped when `cloudOnly`)
class LocalVisionService {
  final MoondreamService _md;
  final OnnxVisionService _onnx;
  final MlKitAnalyzer _mlkit;
  final FlashlightService _flash;
  final Future<VisionGateResult> Function(Uint8List)? _gateCheckOverride;

  LocalVisionService._()
      : _md = MoondreamService.instance,
        _onnx = OnnxVisionService.instance,
        _mlkit = MlKitAnalyzer(),
        _flash = FlashlightService.instance,
        _gateCheckOverride = null;

  static final LocalVisionService instance = LocalVisionService._();

  static Future<VisionGateResult> _alwaysVisibleGate(Uint8List _) async =>
      const VisionGateResult(
        visible: true,
        tooDark: false,
        blocked: false,
        brightness: 120,
        stdDev: 40,
        reason: 'ok',
      );

  /// Test constructor with fake tiers. Defaults [gateCheck] to visible so
  /// synthetic non-JPEG byte buffers can exercise the cascade unless overridden.
  @visibleForTesting
  LocalVisionService.forTest({
    MoondreamService? moondream,
    OnnxVisionService? onnx,
    MlKitAnalyzer? mlkit,
    FlashlightService? flash,
    Future<VisionGateResult> Function(Uint8List)? gateCheck,
  })  : _md = moondream ?? MoondreamService.instance,
        _onnx = onnx ?? OnnxVisionService.instance,
        _mlkit = mlkit ?? MlKitAnalyzer(),
        _flash = flash ?? FlashlightService.instance,
        _gateCheckOverride = gateCheck ?? _alwaysVisibleGate;

  bool _ready = false;
  bool get isReady => _ready;

  VisionGateResult? lastGate;
  String lastEngine = 'idle';
  List<OnnxPrediction> lastTopK = const [];
  String? lastCloudAnalysis;

  String? moondreamModelPath;
  bool get moondreamAvailable => moondreamModelPath != null;
  bool get cloudEnabled => _md.isCloudConfigured;

  Future<void> init() async {
    if (_ready) return;
    await _mlkit.init();
    _ready = true;
  }

  /// Describe a single JPEG frame.
  ///
  /// When [cloudOnly] is `true` ("Cloud-only models, except YOLO26-Nano"),
  /// non-YOLO local fallback models (local Moondream GGUF, ONNX classifier,
  /// ML Kit) are skipped so only Moondream3 Cloud is queried here.
  Future<String?> describe(
    Uint8List jpegBytes, {
    String lang = 'en',
    bool cloudOnly = false,
  }) async {
    if (!_ready) await init();
    lastTopK = const [];
    lastCloudAnalysis = null;

    // ---- 0. VISION GATE ----
    final gate = _gateCheckOverride != null
        ? await _gateCheckOverride!(jpegBytes)
        : await VisionGate.check(jpegBytes);
    lastGate = gate;

    if (!gate.visible) {
      lastEngine = 'gate_blocked';
      if (gate.tooDark && !_flash.isOn) {
        unawaited(_flash.autoTurnOn());
      }
      debugPrint(
        '[VisionGate] Frame blocked (${gate.reason}): '
        'brightness=${gate.brightness.toStringAsFixed(1)}, '
        'stdDev=${gate.stdDev.toStringAsFixed(1)}',
      );
      return null;
    }

    if (_flash.autoManaged && gate.brightness > 90) {
      unawaited(_flash.releaseAuto());
    }

    // ---- 1. PRIMARY: Moondream3 cloud ----
    if (_md.isCloudConfigured) {
      final cloud = await _tryCloud(jpegBytes, lang: lang);
      if (cloud != null) {
        lastEngine = 'moondream_cloud';
        return cloud;
      }
    }

    // When "Cloud-only models (except YOLO)" is active, do NOT run local GGUF,
    // local ONNX classifier, or local ML Kit.
    if (cloudOnly) {
      lastEngine = 'idle';
      return null;
    }

    // ---- 2. OFFLINE FALLBACK #1: on-device Moondream (llama.cpp GGUF) ----
    if (moondreamModelPath != null) {
      final local = await _md.localCaption(
        jpegBytes,
        ggufPath: moondreamModelPath,
        prompt: lang.startsWith('ar')
            ? 'صف هذه الصورة العلمية بجملة قصيرة.'
            : 'Describe this image in one short factual sentence.',
      );
      if (local != null) {
        lastEngine = 'moondream_local';
        return local;
      }
    }

    // ---- 3. OFFLINE FALLBACK #2: specialized ONNX classifier ----
    if (_onnx.isReady) {
      final preds = await _onnx.classify(jpegBytes, k: 3);
      if (preds != null && preds.isNotEmpty) {
        lastTopK = preds;
        lastEngine = 'onnx';
        final best = preds.first;
        final pct = (best.confidence * 100).toStringAsFixed(0);
        return lang.startsWith('ar')
            ? 'النموذج المحلي: ${best.label} ($pct%)'
            : '${best.label} ($pct%)';
      }
    }

    // ---- 4. OFFLINE FALLBACK #3: ML Kit labeling + OCR ----
    final ml = await _mlkit.describe(jpegBytes, lang: lang);
    if (ml != null) {
      lastEngine = 'mlkit';
      return ml;
    }

    lastEngine = 'idle';
    return null;
  }

  Future<String?> _tryCloud(Uint8List jpegBytes, {required String lang}) async {
    final analysis = await _md.analyzeScene(jpegBytes, lang: lang);
    if (analysis == null || analysis.caption.trim().isEmpty) return null;

    lastCloudAnalysis = analysis.toMergedSummary();
    final cap = analysis.caption.trim();
    return lang.startsWith('ar') ? 'موندريم يرى: $cap' : 'Moondream sees: $cap';
  }

  Future<void> dispose() async {
    _onnx.dispose();
    await _mlkit.dispose();
  }
}
