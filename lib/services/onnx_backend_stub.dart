import 'dart:typed_data';

import 'onnx_prediction.dart';

/// Web stub for the ONNX Runtime backend (dart:ffi is unavailable in
/// browsers). The vision cascade treats "classify == null" as "tier
/// unavailable" and continues to ML Kit / cloud tiers.
class OnnxVisionService {
  OnnxVisionService._();
  static final OnnxVisionService instance = OnnxVisionService._();

  bool get isReady => false;
  int get labelCount => 0;

  Future<void> init() async {}

  Future<List<OnnxPrediction>?> classify(
    Uint8List jpegBytes, {
    int k = 3,
  }) async =>
      null;

  void dispose() {}
}
