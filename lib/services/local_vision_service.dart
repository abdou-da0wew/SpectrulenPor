import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

import 'onnx_vision_service.dart';

/// Local on-device vision — the app's "specialized analysis brain".
///
/// Priority order (fastest first):
///   1. ONNX Runtime Mobile — quantized specialized classifier (primary).
///   2. Moondream2 VLM via native platform channel (when GGUF is deployed).
///   3. Google ML Kit image labeling (always available fallback).
/// ML Kit OCR runs on top of whichever labeler wins, so chemical labels on
/// bottles / signs get read out loud.
///
/// Everything here runs ON THE PHONE — the ESP32-CAM only captures and
/// streams; per the project paper all processing happens in this app.
class LocalVisionService {
  LocalVisionService._();
  static final LocalVisionService instance = LocalVisionService._();

  late final ImageLabeler _labeler;
  late final TextRecognizer _ocr;
  bool _ready = false;
  bool get isReady => _ready;

  /// Which engine produced the last description (for UI + logging).
  String lastEngine = 'idle';

  /// Top-k predictions from the ONNX model for the last describe() call
  /// (cached here so callers never run inference twice — latency matters).
  List<OnnxPrediction> lastTopK = const [];

  static const MethodChannel _moondream =
      MethodChannel('com.spectraglass/llama');
  String? moondreamModelPath;
  bool get moondreamAvailable =>
      moondreamModelPath != null && moondreamModelPath!.isNotEmpty;

  Future<void> init() async {
    _labeler = ImageLabeler(
      options: ImageLabelerOptions(confidenceThreshold: 0.55),
    );
    _ocr = TextRecognizer(script: TextRecognitionScript.latin);
    _ready = true;
    debugPrint('[LocalVision] ready — ONNX-first pipeline.');
  }

  /// Produce a concise spoken-style description for an incoming JPEG.
  ///
  /// [lang] is 'en' or 'ar' and only changes the sentence template; raw
  /// class labels stay Latin (they map to ImageNet / dataset names).
  Future<String?> describe(Uint8List jpegBytes, {String lang = 'en'}) async {
    if (!_ready) return null;

    // 1) Specialized ONNX model (primary, <100ms on modern phones).
    final onnx = await OnnxVisionService.instance.classify(jpegBytes, k: 3);
    lastTopK = onnx ?? const [];
    if (onnx != null && onnx.isNotEmpty) {
      lastEngine = 'onnx';
      final best = onnx.first;
      final isAr = lang.startsWith('ar');
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

    // 2) Moondream2 VLM through the native channel (if deployed).
    if (moondreamAvailable) {
      final caption = await _describeWithMoondream(jpegBytes);
      if (caption != null && caption.isNotEmpty) {
        lastEngine = 'moondream';
        return caption;
      }
    }

    // 3) ML Kit fallback.
    lastEngine = 'mlkit';
    lastTopK = const [];
    return _describeWithMlKit(jpegBytes, lang);
  }

  Future<String> _describeWithMlKit(Uint8List jpegBytes, String lang) async {
    final tmp = await _writeTempJpg(jpegBytes);
    final inputImage = InputImage.fromFile(tmp);

    final labels = await _labeler.processImage(inputImage);
    final ocr = await _ocr.processImage(inputImage);
    await tmp.delete();

    final buf = StringBuffer();
    if (labels.isNotEmpty) {
      final top = labels.take(3).map((l) => l.label.toLowerCase()).join(', ');
      buf.write(lang.startsWith('ar')
          ? 'أرى أمامك: $top'
          : 'In front of you I see $top');
    } else {
      buf.write(lang.startsWith('ar')
          ? 'لا أستطيع تصنيف هذا بثقة كافية.'
          : 'I can see something but cannot classify it confidently.');
    }

    final text = ocr.text.trim();
    if (text.isNotEmpty && text.length < 200) {
      buf.write(lang.startsWith('ar')
          ? '. نص مرئي: "${text.replaceAll('\n', ' ')}".'
          : '. Visible text: "${text.replaceAll('\n', ' ')}".');
    }
    return buf.toString();
  }

  /// Calls the native llama.cpp + mmproj Moondream2 engine.
  ///
  /// Native side: android/.../MainActivity.kt + cpp/moondream_jni.cpp.
  /// Returns null when the native engine is missing or errors out, so the
  /// pipeline keeps flowing through fallbacks instead of stalling.
  Future<String?> _describeWithMoondream(Uint8List jpegBytes) async {
    try {
      final result = await _moondream.invokeMethod<String>(
        'moondream_caption',
        {
          'modelPath': moondreamModelPath,
          'jpgBytes': jpegBytes,
          'prompt': 'Describe this image in one short sentence.',
          'maxTokens': 48,
        },
      );
      return result;
    } on MissingPluginException {
      debugPrint('[LocalVision] Moondream native engine not built yet — '
          'falling back. See README (Moondream native build).');
      return null;
    } catch (e) {
      debugPrint('[LocalVision] Moondream error: $e');
      return null;
    }
  }

  /// Enable the Moondream path (call once the GGUF is on the device).
  Future<void> enableMoondream(String ggufPath) async {
    moondreamModelPath = ggufPath;
    debugPrint('[LocalVision] Moondream enabled: $ggufPath');
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
