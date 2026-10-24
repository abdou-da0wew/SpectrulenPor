/// One prediction from the specialized ONNX model (shared by the IO and web
/// stub backends).
class OnnxPrediction {
  final String label;
  final double confidence; // 0..1
  final int classIndex;

  OnnxPrediction(this.label, this.confidence, this.classIndex);
}
