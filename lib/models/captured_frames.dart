import 'dart:typed_data';

import 'bounding_box.dart';

/// Paired capture: one JPEG with bounding boxes drawn on it, one clean JPEG
/// (no boxes). Both go to Moondream so the AI sees the spatial layout (boxes
/// image) AND the unobstructed view (clean image) for color/texture analysis.
class CapturedFrames {
  final Uint8List cleanJpeg;       // no boxes
  final Uint8List withBoxesJpeg;   // boxes painted on
  final BoundingBox selectedBox;    // the box the user tapped
  final DateTime capturedAt;

  const CapturedFrames({
    required this.cleanJpeg,
    required this.withBoxesJpeg,
    required this.selectedBox,
    required this.capturedAt,
  });
}
