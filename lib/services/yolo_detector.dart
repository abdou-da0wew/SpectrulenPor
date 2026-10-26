import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/bounding_box.dart';

/// YOLO26-Nano on-device object detector — runs natively via the
/// YoloInferenceChannel (Kotlin) which loads the bundled ONNX model
/// (assets/models/yolo26n.onnx) using ONNX Runtime.
///
/// Pipeline: JPEG bytes → letterbox 640×640 → NCHW float32 normalized →
/// ONNX inference → YOLO26 [1, 84, 8400] output parse → NMS → un-letterbox
/// → List<BoundingBox> (normalized 0..1).
///
/// COCO 80-class labels (person, car, bottle, cup, laptop, etc.) are
/// returned from the Kotlin side via the `labels` method call.
class YoloDetector {
  YoloDetector._();
  static final YoloDetector instance = YoloDetector._();

  static const MethodChannel _channel = MethodChannel('com.spectraglass/yolo');

  bool _ready = false;
  bool get isReady => _ready;
  String get backendName => 'yolo26nano';

  List<String>? _labels;
  List<String> get labels => _labels ?? const [];

  Future<void> init() async {
    if (_ready) return;
    try {
      final ok = await _channel.invokeMethod<bool>('init');
      _ready = ok == true;
      if (_ready) {
        try {
          final l = await _channel.invokeMethod<List<dynamic>>('labels');
          _labels = l?.map((e) => e.toString()).toList() ?? const [];
        } catch (_) {}
        debugPrint('[YoloDetector] ready — ${_labels?.length ?? 0} COCO labels');
      }
    } on MissingPluginException {
      debugPrint('[YoloDetector] native channel not registered');
    } catch (e) {
      debugPrint('[YoloDetector] init failed: $e');
    }
  }

  /// Run detection on a JPEG. Boxes are normalized 0..1 in original-image
  /// coordinates (NOT preview coordinates — caller must convert).
  Future<List<BoundingBox>> detect(Uint8List jpegBytes) async {
    if (!_ready) return const [];
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('detect', <String, dynamic>{
        'jpgBytes': jpegBytes,
      });
      if (result == null) return const [];
      final boxes = <BoundingBox>[];
      for (final e in result) {
        if (e is Map) {
          final x = (e['x'] as num?)?.toDouble() ?? 0.0;
          final y = (e['y'] as num?)?.toDouble() ?? 0.0;
          final w = (e['w'] as num?)?.toDouble() ?? 0.0;
          final h = (e['h'] as num?)?.toDouble() ?? 0.0;
          final label = (e['label'] as String?) ?? 'object';
          final conf = (e['confidence'] as num?)?.toDouble() ?? 0.0;
          boxes.add(BoundingBox(
            x: x, y: y, w: w, h: h, label: label, confidence: conf,
          ));
        }
      }
      return boxes;
    } catch (e) {
      debugPrint('[YoloDetector] detect failed: $e');
      return const [];
    }
  }

  void dispose() {
    _ready = false;
    _labels = null;
  }
}
