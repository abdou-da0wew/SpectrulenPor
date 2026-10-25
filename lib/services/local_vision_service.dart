import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'flashlight_service.dart';
import 'moondream_service.dart';
import 'onnx_prediction.dart';
import 'onnx_vision_service.dart';
import 'vision_gate.dart';
import 'vision_mlkit.dart';

/// Vision cascade for SpectruLenPor — who looks at the frame, in order:
///
///   0. **VISION GATE** (always) — brightness + variance + blur + blocked.
///      If the gate fails, NO model call is made — we don't waste cloud
///      quota on pitch-dark / blank / motion-blurred frames.
///   1. **Moondream3 CLOUD** (primary) — `moondream3.1-9B-A2B` via
///      api.moondream.ai. Multi-pass analyzeScene() = caption + VQA +
///      text-detect + hazard-check, merged into structured context.
///   2. **Local Moondream** (fallback) — GGUF via native platform channel
///      `com.spectraglass/llama` (llama.cpp + mmproj). Works offline.
///   3. **ONNX Runtime Mobile** — specialized quantized classifier
///      (<100 ms, offline) when assets/models/ is populated.
///   4. **ML Kit** (always available on device) — image labeling + OCR.
///
/// All tiers are injectable so the unit-test suite can exercise the full
/// cascade ordering with fakes.
class LocalVisionService {
  final MoondreamService _md;
  final OnnxVisionService _onnx;
  final MlKitAnalyzer _mlkit;
  final FlashlightService _flash;

  /// Production singleton.
  LocalVisionService._()
      : _md = MoondreamService.instance,
        _onnx = OnnxVisionService.instance,
        _mlkit = MlKitAnalyzer(),
        _flash = FlashlightService.instance;

  static final LocalVisionService instance = LocalVisionService._();

  /// Test constructor with fake tiers.
  @visibleForTesting
  LocalVisionService.forTest({
    MoondreamService? moondream,
    OnnxVisionService? onnx,
    MlKitAnalyzer? mlkit,
    FlashlightService? flash,
  })  : _md = moondream ?? MoondreamService.instance,
        _onnx = onnx ?? OnnxVisionService.instance,
        _mlkit = mlkit ?? MlKitAnalyzer(),
        _flash = flash ?? FlashlightService.instance;

  bool _ready = false;
  bool get isReady => _ready;

  /// Last vision-gate result. Read by RecognitionState to decide whether to
  /// auto-enable the torch (tooDark) and to gate upstream calls.
  VisionGateResult? lastGate;

  /// Which engine produced the last description ('moondream_cloud' |
  /// 'moondream_local' | 'onnx' | 'mlkit' | 'idle' | 'gate_blocked').
  String lastEngine = 'idle';

  /// Top-k predictions when the ONNX engine won (empty otherwise).
  List<OnnxPrediction> lastTopK = const [];

  /// Full cloud answer from the last Moondream3 multi-pass analyzeScene() call.
  /// This is the rich structured context (caption + chemistry VQA + text
  /// count + hazard check) that gets fed to OpenRouter for the spoken
  /// narration. Falls back to last simple caption if multi-pass fails.
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
    debugPrint('[LocalVision] ready — vision-gated Moondream3 cascade.');
  }

  bool get cloudEnabled => _md.isCloudConfigured;

  /// Returns true if the most-recent frame was too dark AND not blocked.
  /// RecognitionState uses this to drive the AUTO-FLASHLIGHT logic.
  bool get lastFrameWasTooDark =>
      lastGate != null && lastGate!.tooDark && !lastGate!.blocked;

  /// Produce a concise spoken-style description for an incoming JPEG.
  ///
  /// The pipeline runs the VISION GATE FIRST. If the frame is pitch-dark /
  /// blank / blocked / blurred, returns null and sets [lastEngine]='gate_blocked'.
  /// RecognitionState then: (a) doesn't call upstream, (b) auto-enables the
  /// torch if [lastFrameWasTooDark], and (c) waits for the next brighter frame.
  Future<String?> describe(Uint8List jpegBytes, {String lang = 'en'}) async {
    if (!_ready) return null;
    final isAr = lang.startsWith('ar');

    // ============================================================
    // 0. VISION GATE — never call a model on a bad frame.
    // ============================================================
    final gate = await VisionGate.check(jpegBytes);
    lastGate = gate;
    if (!gate.visible) {
      lastEngine = 'gate_blocked';
      lastTopK = const [];
      // Don't clear the cached cloud analysis — the UI still shows the
      // last good analysis as "best-known" while the user re-aims.
      return null;
    }

    // ============================================================
    // 1. MOONDREAM3 CLOUD — multi-pass analyzeScene (smarter than caption).
    // ============================================================
    if (cloudEnabled) {
      final analysis = await _md.analyzeScene(jpegBytes, lang: lang);
      if (analysis != null && analysis.toMergedSummary().isNotEmpty) {
        lastEngine = 'moondream_cloud';
        lastTopK = const [];
        lastCloudAnalysis = analysis.toMergedSummary();
        lastCloudReasoning = analysis.reasoning;

        // For the INSTANT spoken label (live-speak), use the short caption
        // Pass 1 result — it's already available and is fast.
        final cap = analysis.caption.trim();
        return isAr ? 'موندريم يرى: $cap' : 'Moondream sees: $cap';
      }

      // Fallback to single-shot caption if multi-pass failed at Pass 1.
      final single = await _md.caption(jpegBytes, length: 'short');
      if (single != null && single.caption.trim().isNotEmpty) {
        lastEngine = 'moondream_cloud';
        lastCloudAnalysis = single.caption.trim();
        final cc = single.caption.trim();
        return isAr ? 'موندريم يرى: $cc' : 'Moondream sees: $cc';
      }
    }

    // ============================================================
    // 2. LOCAL MOONDREAM — offline VLM fallback, with smarter prompt.
    // ============================================================
    if (moondreamAvailable) {
      // Smarter local prompt: ask for specifics (colors, state, labels)
      // rather than "Describe this image in one short sentence." which
      // produces generic unhelpful captions.
      final localPrompt = isAr
          ? 'صف بدقة: ما هو لون المادة؟ هل هي صلبة أم سائلة أم غازية؟ '
              'هل ترى أي ملصقات أو نصوص على العبوة؟ كن مختصراً ودقيقاً.'
          : 'Describe precisely: what color is the substance? Is it solid, '
              'liquid, or gas? Are there any labels or printed text on the '
              'container? Be brief and specific.';
      final caption = await _md.localCaption(
        jpegBytes,
        ggufPath: moondreamModelPath,
        prompt: localPrompt,
      );
      if (caption != null && caption.trim().isNotEmpty) {
        lastEngine = 'moondream_local';
        lastTopK = const [];
        lastCloudAnalysis = caption.trim();
        return caption.trim();
      }
    }

    // ============================================================
    // 3. ONNX — specialized quantized classifier (<100 ms, offline).
    // ============================================================
    final onnx = await _onnx.classify(jpegBytes, k: 3);
    lastTopK = onnx ?? const [];
    if (onnx != null && onnx.isNotEmpty) {
      lastEngine = 'onnx';
      final best = onnx.first;
      final alt = onnx.length > 1
          ? isAr
              ? ' أو ربما ${onnx[1].label} '
              : ' or maybe ${onnx[1].label}'
          : '';
      final pct = ((best.confidence * 100).round()).clamp(0, 100);
      lastCloudAnalysis = '$best.label (${pct}%)';
      return isAr
          ? '$best.label (${pct}%)$alt'
          : '$best.label (${pct}%)$alt';
    }

    // ============================================================
    // 4. ML KIT — labeling + OCR (always available on device).
    // ============================================================
    final mlkitDesc = await _mlkit.describe(jpegBytes, isAr: isAr);
    if (mlkitDesc != null && mlkitDesc.trim().isNotEmpty) {
      lastEngine = 'mlkit';
      lastCloudAnalysis = mlkitDesc;
      return mlkitDesc;
    }

    lastEngine = 'idle';
    return null;
  }

  /// Tell the flashlight to turn on (called by RecognitionState when the gate
  /// reports too-dark). Returns true if the torch was successfully lit.
  Future<bool> requestAutoFlashlight() async {
    return await _flash.setTorch(true);
  }

  /// Tell the flashlight to turn off (when scene brightens again).
  Future<bool> releaseAutoFlashlight() async {
    return await _flash.setTorch(false);
  }
}
