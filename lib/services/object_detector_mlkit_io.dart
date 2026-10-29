import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart' as ml;
import 'package:path_provider/path_provider.dart';

import '../models/bounding_box.dart';
import 'object_detector_mlkit.dart';

/// Android/iOS implementation of [ObjectDetector] using Google ML Kit Object
/// Detection. The default mode uses ML Kit's bundled model (no asset needed).
///
/// The detected bounding boxes are returned in PIXEL coordinates (ML Kit's
/// native format). The caller (RecognitionState) converts them to normalized
/// 0..1 coordinates using the known source image dimensions (from
/// PhoneCameraService.frameStream's FrameData width/height).
class _MlKitObjectDetectorImpl implements ObjectDetector {
  _MlKitObjectDetectorWrapper? _detector;
  bool _ready = false;

  @override
  bool get isReady => _ready;

  @override
  String get backendName => 'mlkit';

  @override
  Future<void> init() async {
    if (_ready) return;
    final options = ml.ObjectDetectorOptions(
      mode: ml.DetectionMode.stream,             // optimized for video frames
      classifyObjects: true,                  // we want labels
      multipleObjects: true,                 // all visible objects
    );
    _detector = _MlKitObjectDetectorWrapper(options);
    _ready = true;
    debugPrint('[ObjectDetector] ML Kit ready');
  }

  @override
  Future<List<BoundingBox>> detect(Uint8List jpegBytes) async {
    if (!_ready) return const [];
    try {
      final tmp = await _writeTempJpg(jpegBytes);
      final inputImage = ml.InputImage.fromFile(tmp);
      final objects = await _detector!
          .processImage(inputImage);
      await tmp.delete();
      return objects.map(_toBoundingBox).toList(growable: false);
    } catch (e) {
      debugPrint('[ObjectDetector] detect failed: $e');
      return const [];
    }
  }

  @override
  void dispose() {
    _detector = null;
    _ready = false;
  }

  // ---- helpers ----

  Future<File> _writeTempJpg(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/sp_detect_${DateTime.now().microsecondsSinceEpoch}.jpg');
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  /// NOTE: ML Kit returns PIXEL coordinates. Caller normalizes via
  /// FrameData.width/height. We stash the pixels here; the overlay
  /// widget divides by source image size at paint time.
  BoundingBox _toBoundingBox(ml.DetectedObject o) {
    final rect = o.boundingBox;
    final label = o.labels.isEmpty
        ? 'object'
        : o.labels.reduce((a, b) => a.confidence > b.confidence ? a : b).text;
    final conf = o.labels.isEmpty ? 0.5 : o.labels.first.confidence;
    // Return PIXEL coordinates for now — overlay will normalize.
    return BoundingBox(
      x: rect.left.toDouble(),
      y: rect.top.toDouble(),
      w: rect.width.toDouble(),
      h: rect.height.toDouble(),
      label: label,
      confidence: conf,
    );
  }
}

class _MlKitObjectDetectorWrapper {
  final ml.ObjectDetectorOptions options;
  late final ml.ObjectDetector _native;
  _MlKitObjectDetectorWrapper(this.options) {
    _native = ml.ObjectDetector(options: options);
  }
  Future<List<ml.DetectedObject>> processImage(ml.InputImage img) =>
      _native.processImage(img);
}

/// Factory called by object_detector_mlkit.dart's conditional export.
ObjectDetector createDelegate() => _MlKitObjectDetectorImpl();
