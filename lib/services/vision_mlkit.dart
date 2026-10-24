/// Conditional ML Kit analyzer (labeling + OCR):
///   * VM / Android / iOS -> real Google ML Kit implementation
///   * Web -> stub (ML Kit has no web engine; cascade skips this tier)
export 'vision_mlkit_io.dart' if (dart.library.html) 'vision_mlkit_stub.dart';
