import 'dart:typed_data';

import '../models/bounding_box.dart';
import 'object_detector_mlkit_io.dart';

/// Abstract object-detector interface shared across platforms.
abstract class ObjectDetector {
  Future<void> init();
  Future<List<BoundingBox>> detect(Uint8List jpegBytes);
  void dispose();
  bool get isReady;
  String get backendName;  // 'mlkit' | 'yolo26nano'
}

/// Concrete ML Kit detector singleton (delegates to the platform impl).
class MlKitObjectDetector implements ObjectDetector {
  MlKitObjectDetector._();
  static final MlKitObjectDetector instance = MlKitObjectDetector._();

  static final ObjectDetector _impl = createDelegate();
  bool _ready = false;

  @override
  bool get isReady => _ready;
  @override
  String get backendName => _impl.backendName;

  @override
  Future<void> init() async {
    if (_ready) return;
    await _impl.init();
    _ready = _impl.isReady;
  }

  @override
  Future<List<BoundingBox>> detect(Uint8List jpegBytes) => _impl.detect(jpegBytes);

  @override
  void dispose() => _impl.dispose();
}
