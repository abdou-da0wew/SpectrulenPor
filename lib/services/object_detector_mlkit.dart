import 'dart:typed_data';

import '../models/bounding_box.dart';

/// Abstract object-detector interface. Two implementations:
///   * [MlKitObjectDetector] — Google ML Kit, free, real-time, no asset needed.
///   * YoloObjectDetector (future) — YOLO26-Nano via ultralytics_yolo (requires
///     the YOLO26 TFLite asset under assets/models/yolo26nano.tflite).
///
/// The pipeline calls [detect] on each throttled frame (1-4 fps). The result
/// is a list of normalized [BoundingBox]es that the overlay widget paints on
/// the camera preview.
abstract class ObjectDetector {
  Future<void> init();
  Future<List<BoundingBox>> detect(Uint8List jpegBytes);
  void dispose();
  bool get isReady;
  String get backendName;  // 'mlkit' | 'yolo26nano'
}

// Conditional export picks io or stub based on platform.
export 'object_detector_mlkit_io.dart'
    if (dart.library.html) 'object_detector_mlkit_stub.dart'
    show createDelegate;

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
