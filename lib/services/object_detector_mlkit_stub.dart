import 'dart:typed_data';

import '../models/bounding_box.dart';
import 'object_detector_mlkit.dart';

/// Web stub — ML Kit Object Detection is mobile-only. Returns no boxes.
class _StubObjectDetector implements ObjectDetector {
  @override
  bool get isReady => false;
  @override
  String get backendName => 'stub';
  @override
  Future<void> init() async {}
  @override
  Future<List<BoundingBox>> detect(Uint8List jpegBytes) async => const [];
  @override
  void dispose() {}
}

ObjectDetector createDelegate() => _StubObjectDetector();
