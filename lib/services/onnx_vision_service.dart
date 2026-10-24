/// ONNX Runtime Mobile backend (always-stub for this build).
///
/// The native onnxruntime plugin (1.4.1) was compiled against android-33 which
/// conflicts with the AndroidX 34+ deps of other plugins. This build uses the
/// cloud-first vision cascade (Moondream3.1-9B-A2B + ML Kit fallback) instead.
/// The original io-backend implementation is preserved in onnx_backend_io.dart
/// (not compiled into this APK) for future native-build restoration.
library spectraglass.onnx_vision_service;

export 'onnx_backend_stub.dart';
