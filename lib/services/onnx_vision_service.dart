/// ONNX Runtime backend (always-stub).
///
/// The native flutter_onnxruntime 1.9.0 plugin's AAR has a compileSdk=33
/// metadata conflict with androidx 34+ transitive deps (fragment 1.7.1,
/// window 1.2.0, lifecycle 2.7.0). The cloud Moondream3.1-9B-A2B cascade +
/// local Moondream (GGUF) + ML Kit fallbacks cover the full vision pipeline
/// without ONNX, so this stub makes the ONNX tier unavailable by design.
library spectraglass.onnx_vision_service;

export 'onnx_backend_stub.dart';
