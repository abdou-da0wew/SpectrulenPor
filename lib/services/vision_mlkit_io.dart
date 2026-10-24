import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

/// Real ML Kit tier — fast offline labeling + OCR. Runs LAST in the vision
/// cascade (after Moondream3 cloud, local Moondream and ONNX), but its OCR
/// pass is what reads chemical bottle labels and warning signs out loud.
class MlKitAnalyzer {
  ImageLabeler? _labeler;
  TextRecognizer? _ocr;
  bool _ready = false;
  bool get isReady => _ready;

  Future<void> init() async {
    _labeler ??= ImageLabeler(
      options: ImageLabelerOptions(confidenceThreshold: 0.55),
    );
    _ocr ??= TextRecognizer(script: TextRecognitionScript.latin);
    _ready = true;
  }

  /// Compose a spoken-style sentence from labels + OCR, or null when the
  /// analyzers yield nothing usable.
  Future<String?> describe(Uint8List jpegBytes, {required bool isAr}) async {
    if (!_ready) return null;
    try {
      final tmp = await _writeTempJpg(jpegBytes);
      final inputImage = InputImage.fromFile(tmp);

      final labels = await _labeler!.processImage(inputImage);
      final ocr = await _ocr!.processImage(inputImage);
      await tmp.delete();

      final buf = StringBuffer();
      if (labels.isNotEmpty) {
        final top =
            labels.take(3).map((l) => l.label.toLowerCase()).join(', ');
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
    } catch (e) {
      debugPrint('[MlKit] describe failed: $e');
      return null;
    }
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
    _labeler?.close();
    _ocr?.close();
  }
}
