import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

/// Local on-device vision.
///
/// Production plan:
///   1. (Default) Run Google ML Kit Image Labeling + Object Detection + OCR
///      for instant (~100-300ms) descriptive labels. ML Kit ships pre-trained
///      default models bundled in the plugin, so no extra downloads needed.
///   2. (Optional, advanced) If you have a Moondream2 GGUF model
///      (~1.1 GB Q4_K_M) plus a native llama.cpp + mmproj binding, set
///      `useMoondream = true` and implement `describeWithMoondream()` via
///      a MethodChannel. The interface below is unchanged so the rest of
///      the app keeps working.
///
/// The local label is what gets spoken immediately and forwarded upstream
/// as text context to OpenRouter for deep reasoning.
class LocalVisionService {
  LocalVisionService._();
  static final LocalVisionService instance = LocalVisionService._();

  late final ImageLabeler _labeler;
  late final ObjectDetector _detector;
  late final TextRecognizer _ocr;

  bool _ready = false;
  bool get isReady => _ready;

  bool useMoondream = false;
  String? moondreamModelPath;

  Future<void> init() async {
    // Default Image Labeler (uses Google's bundled default model).
    _labeler = ImageLabeler(
      options: ImageLabelerOptions(confidenceThreshold: 0.55),
    );

    // Default Object Detector.
    _detector = ObjectDetector(
      options: ObjectDetectorOptions(
        mode: DetectionMode.single,
        classifyObjects: true,
        multipleObjects: true,
      ),
    );

    // OCR for signs / product labels (Latin + script-aware in ML Kit).
    _ocr = TextRecognizer(script: TextRecognitionScript.latin);

    _ready = true;
    debugPrint('[LocalVisionService] ready (ML Kit path active).');
  }

  /// Produce a concise spoken-style description for an incoming JPEG.
  ///
  /// Output looks like:
  ///   "In front of you is a glass beaker. Visible text: 'NaCl 0.9%'."
  Future<String?> describe(Uint8List jpegBytes) async {
    if (!_ready) return null;
    if (useMoondream && moondreamModelPath != null) {
      return describeWithMoondream(jpegBytes);
    }
    return describeWithMlKit(jpegBytes);
  }

  Future<String> describeWithMlKit(Uint8List jpegBytes) async {
    // Write bytes to a temp file because ML Kit's InputImage.fromBytes path
    // requires a decoded format we don't have on the BLE chunk level.
    final tmp = await _writeTempJpg(jpegBytes);
    final inputImage = InputImage.fromFile(tmp);

    final labelsFuture = _labeler.processImage(inputImage);
    final objectsFuture = _detector.processImage(inputImage);
    final ocrFuture = _ocr.processImage(inputImage);

    final labels = await labelsFuture;
    final objects = await objectsFuture;
    final ocr = await ocrFuture;

    await tmp.delete();

    // Compose a spoken sentence.
    final buf = StringBuffer();

    // Object detection gives bounding boxes; we summarize with top labels.
    final objectLabels = <String>{};
    for (final o in objects) {
      for (final l in o.labels) {
        if (l.confidence > 0.5) objectLabels.add(l.label);
      }
    }
    if (labels.isNotEmpty) {
      final top = labels.take(3).map((l) => l.label.toLowerCase()).join(', ');
      buf.write('In front of you I see $top');
    } else if (objectLabels.isNotEmpty) {
      buf.write('In front of you I see ${objectLabels.join(', ')}');
    } else {
      buf.write('I can see something but cannot classify it confidently.');
    }

    // Append OCR text if visible.
    final cleanedText = ocr.text.trim();
    if (cleanedText.isNotEmpty && cleanedText.length < 200) {
      buf.write('. Visible text: "${cleanedText.replaceAll('\n', ' ')}".');
    }

    return buf.toString();
  }

  /// Placeholder for a native llama.cpp + Moondream2 binding.
  ///
  /// To enable: add a platform channel in `android/app/src/main/kotlin/...`
  /// that loads the GGUF + mmproj, runs inference, and returns the caption.
  /// Then call it from here:
  ///   final result = await MethodChannel('com.spectraglass/llama')
  ///       .invokeMethod<String>('moondream_caption', {
  ///         'modelPath': moondreamModelPath,
  ///         'jpgBytes': jpegBytes,
  ///         'prompt': 'Describe this image in one short sentence.',
  ///       });
  ///   return result;
  Future<String> describeWithMoondream(Uint8List jpegBytes) async {
    // Until you wire the platform channel, fall back to ML Kit so the app
    // never crashes silently. Log a warning so you notice during dev.
    debugPrint('[LocalVisionService] Moondream requested but native binding '
        'not wired — falling back to ML Kit.');
    return describeWithMlKit(jpegBytes);
  }

  Future<File> _writeTempJpg(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/esp32cam_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final f = File(path);
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  /// Configure the Moondream2 path (called from settings screen).
  Future<void> enableMoondream(String ggufPath) async {
    moondreamModelPath = ggufPath;
    useMoondream = true;
    debugPrint('[LocalVisionService] Moondream enabled: $ggufPath');
  }

  Future<void> disableMoondream() async {
    useMoondream = false;
    moondreamModelPath = null;
  }

  void dispose() {
    _labeler.close();
    _detector.close();
    _ocr.close();
  }
}
