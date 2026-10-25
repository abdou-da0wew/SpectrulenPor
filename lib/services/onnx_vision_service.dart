/// Conditional ONNX Runtime backend:
///   * VM / Android / iOS -> real onnxruntime (flutter_onnxruntime 1.9.0) implementation
///   * Web -> stub (no native libs available)
///
/// Uses flutter_onnxruntime (onnxruntime-android 1.28.0, 16KB-page compatible,
/// supports Android 12-17).
library spectraglass.onnx_vision_service;

export 'onnx_backend_io.dart'
    if (dart.library.html) 'onnx_backend_stub.dart';
