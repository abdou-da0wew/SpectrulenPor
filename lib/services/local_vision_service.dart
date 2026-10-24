import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

import 'moondream_service.dart';
import 'onnx_vision_service.dart';

/// Vision cascade for SpectruLenPor — who looks at the frame, in order:
///
///   1. **Moondream3 CLOUD** (primary) — `moondream3.1-9B-A2B` via
///      api.moondream.ai. Streamed caption gives first words in <1s.
///   2. **Local Moondream** (fallback) — GGUF via native platform channel
///      `com.spectraglass/llama` (llama.cpp + mmproj). Works offline.
///   3. **ONNX Runtime Mobile** — specialized quantized classifier
///      (<100 ms, offline) when assets/models/ is populated.
///   4. **ML Kit** (always available) — image labeling + OCR last resort.
///
/// The winning engine's factual output is what OpenRouter (gemma → inkling
/// → nemotron chain) merely PRESENTS in nicer spoken words. ML Kit OCR runs
/// on top of every frame regardless of which labeler won, so chemical
/// bottle labels / warning signs are always read out.
class LocalVisionService {
  LocalVisionService._();
  static final LocalVisionService instance = LocalVisionService._();

  late final ImageLabeler _labeler;
  late final TextRecognizer _ocr;
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

  MoondreamService get _md => MoondreamService.instance;

  Future<void> init() async {
    _labeler = ImageLabeler(
      options: ImageLabelerOptions(confidenceThreshold: 0.55),
    );
    _ocr = TextRecognizer(script: TextRecognitionScript.latin);
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
        return isAr
            ? 'موندريم يرى: $cc'
            : 'Moondream sees: $cc';
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
    final onnx = await OnnxVisionService.instance.classify(jpegBytes, k: 3);
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

    // 4) ML Kit — image labeling + OCR, always available.
    lastEngine = 'mlkit';
    lastTopK = const [];
    return _describeWithMlKit(jpegBytes, isAr);
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

  Future<String> _describeWithMlKit(Uint8List jpegBytes, bool isAr) async {
    final tmp = await _writeTempJpg(jpegBytes);
    final inputImage = InputImage.fromFile(tmp);

    final labels = await _labeler.processImage(inputImage);
    final ocr = await _ocr.processImage(inputImage);
    await tmp.delete();

    final buf = StringBuffer();
    if (labels.isNotEmpty) {
      final top = labels.take(3).map((l) => l.label.toLowerCase()).join(', ');
      buf.write(isAr ? 'أرى أمامك: $top' : 'In front of you I see $top');
    } else {
      buf.write(isAr
          ? 'لا أستطيع تصنيف هذا بثقة كافية.'
          : 'I can see something but cannot classify it confidently.');
    }

    final text = ocr.text.trim();
    if (text.isNotEmpty && text.length < 200) {
      buf.write(isAr
          ? '. نص مرئي: "${text.replaceAll('\n', ' ')}".'
          : '. Visible text: "${text.replaceAll('\n', ' ')}".');
    }
    return buf.toString();
  }

  /// Enable the local Moondream path (call once the GGUF is on the device).
  Future<void> enableMoondream(String ggufPath) async {
    moondreamModelPath = ggufPath;
    debugPrint('[LocalVision] local Moondream enabled: $ggufPath');
  }

  Future<void> disableMoondream() async {
    moondreamModelPath = null;
  }

  Future<File> _writeTempJpg(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/frame_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final f = File(path);
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  void dispose() {
    _labeler.close();
    _ocr.close();
  }
}
