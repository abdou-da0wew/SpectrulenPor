/// Conditional ONNX Runtime Mobile backend:
///   * VM / Android / iOS -> real onnxruntime (dart:ffi) implementation
///   * Web -> stub (dart:ffi unavailable in browsers)
export 'onnx_backend_io.dart' if (dart.library.html) 'onnx_backend_stub.dart';
