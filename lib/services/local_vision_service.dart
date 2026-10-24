import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'moondream_service.dart';
import 'onnx_prediction.dart';
import 'onnx_vision_service.dart';
import 'vision_mlkit.dart';

/// Vision cascade for SpectruLenPor — who looks at the frame, in order:
///
///   1. **Moondream3 CLOUD** (primary) — `moondream3.1-9B-A2B` via
///      api.moondream.ai. Streamed caption gives first words in <1s.
///   2. **Local Moondream** (fallback) — GGUF via native platform channel
///      `com.spectraglass/llama` (llama.cpp + mmproj). Works offline.
///   3. **ONNX Runtime Mobile** — specialized quantized classifier
///      (<100 ms, offline) when assets/models/ is populated.
///   4. **ML Kit** (always available on device) — image labeling + OCR.
///
/// The winning engine's factual output is what OpenRouter (gemma → inkling
/// → nemotron chain) merely PRESENTS in nicer spoken words.
///
/// All tiers are injectable so the unit-test suite can exercise the full
/// cascade ordering with fakes.
class LocalVisionService {
  final MoondreamService _md;
  final OnnxVisionService _onnx;
  final MlKitAnalyzer _mlkit;

  /// Production singleton.
  LocalVisionService._()
      : _md = MoondreamService.instance,
        _onnx = OnnxVisionService.instance,
        _mlkit = MlKitAnalyzer();

  static final LocalVisionService instance = LocalVisionService._();

  /// Test constructor with fake tiers.
  @visibleForTesting
  LocalVisionService.forTest({
    MoondreamService? moondream,
    OnnxVisionService? onnx,
    MlKitAnalyzer? mlkit,
  })  : _md = moondream ?? MoondreamService.instance,
        _onnx = onnx ?? OnnxVisionService.instance,
        _mlkit = mlkit ?? MlKitAnalyzer();

  bool _ready = false;
  bool get isReady => _ready;

  /// Which engine produced the last description ('moondream_cloud' |
  /// 'moondream_local' | 'onnx' | 'mlkit' | 'idle').
  String lastEngine = 'idle';

  /// Top-k predictions when the ONNX engine won (empty otherwise).
  List<OnnxPrediction> lastTopK = const [];

  /// Full cloud answer from the last Moondream3 query (for OpenRouter).
  String? lastCloudAnalysis;

  /// Reasoning trace from the last Moondream3 query when reasoning was on.
  String? lastCloudReasoning;

  /// Local Moondream GGUF path (Settings sets this when deployed).
  String? moondreamModelPath;
  bool get moondreamAvailable =>
      moondreamModelPath != null && moondreamModelPath!.isNotEmpty;

  Future<void> init() async {
    await _mlkit.init();
    _ready = true;
    debugPrint('[LocalVision] ready — Moondream3-cloud-first cascade.');
  }

  bool get cloudEnabled => _md.isCloudConfigured;

  /// Produce a concise spoken-style description for an incoming JPEG.
  ///
  /// [lang] is 'en' or 'ar' and only changes the sentence template; raw
  /// class labels stay Latin (they map to dataset / ML Kit names).
  Future<String?> describe(Uint8List jpegBytes, {String lang = 'en'}) async {
    if (!_ready) return null;
    final isAr = lang.startsWith('ar');

    // 1) Moondream3 CLOUD — primary analyst (streamed short caption).
    if (cloudEnabled) {
      final cap = await _md.caption(jpegBytes, length: 'short');
      if (cap != null && cap.caption.trim().isNotEmpty) {
        lastEngine = 'moondream_cloud';
        lastTopK = const [];
        // Deep query runs after we already have the caption — it never
        // blocks the first spoken sentence (latency).
        _runDeepQuery(jpegBytes, isAr: isAr);
        final cc = cap.caption.trim();
        return isAr ? 'موندريم يرى: $cc' : 'Moondream sees: $cc';
      }
    }

    // 2) LOCAL MOONDREAM — offline VLM fallback (native GGUF engine).
    if (moondreamAvailable) {
      final caption = await _md.localCaption(
        jpegBytes,
        ggufPath: moondreamModelPath,
      );
      if (caption != null) {
        lastEngine = 'moondream_local';
        lastTopK = const [];
        return caption;
      }
    }

    // 3) ONNX — specialized quantized classifier (<100 ms, offline).
    final onnx = await _onnx.classify(jpegBytes, k: 3);
    lastTopK = onnx ?? const [];
    if (onnx != null && onnx.isNotEmpty) {
      lastEngine = 'onnx';
      final best = onnx.first;
      final alt = onnx.length > 1
          ? isAr
              ? ' أو ربما ${onnx[1].label} '
                  '(${(onnx[1].confidence * 100).toStringAsFixed(0)}٪).'
              : ' — or possibly ${onnx[1].label} '
                  '(${(onnx[1].confidence * 100).toStringAsFixed(0)}%).'
          : '';
      return isAr
          ? 'يبدو أن هذا ${best.label} بثقة '
              '${(best.confidence * 100).toStringAsFixed(0)}٪.$alt'
          : 'This looks like ${best.label} '
              '(${(best.confidence * 100).toStringAsFixed(0)}% confidence)$alt';
    }

    // 4) ML Kit — image labeling + OCR, always available on device.
    final ml = await _mlkit.describe(jpegBytes, isAr: isAr);
    if (ml != null) {
      lastEngine = 'mlkit';
      lastTopK = const [];
      return ml;
    }

    lastEngine = 'idle';
    return null;
  }

  /// Fire-and-forget deep query on the cloud tier. Fills
  /// [lastCloudAnalysis] (+ optional reasoning trace) which the OpenRouter
  /// presenter then rephrases. Never blocks the spoken caption.
  Future<void> _runDeepQuery(
    Uint8List jpegBytes, {
    required bool isAr,
  }) async {
    final question = isAr
        ? 'صف ما في الصورة: المادة أو الجهاز، أي نص مرئي على الملصقات، '
            'اللون والحالة (صلب/سائل/غاز) وأي مؤشرات خطر.'
        : 'Describe what is in this image: the substance or device, any '
            'visible label text, color and state (solid/liquid/gas) and any '
            'hazard indicators.';
    final ans = await _md.query(jpegBytes, question: question);
    if (ans != null && ans.answer.trim().isNotEmpty) {
      lastCloudAnalysis = ans.answer.trim();
      lastCloudReasoning = ans.reasoning;
    }
  }

  /// Enable the local Moondream path (call once the GGUF is on the device).
  Future<void> enableMoondream(String ggufPath) async {
    moondreamModelPath = ggufPath;
    debugPrint('[LocalVision] local Moondream enabled: $ggufPath');
  }

  Future<void> disableMoondream() async {
    moondreamModelPath = null;
  }

  void dispose() {
    _mlkit.dispose();
  }
}
