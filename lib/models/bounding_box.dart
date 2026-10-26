import 'dart:ui';

/// One detected object in a frame, with a normalized bounding box
/// (0.0..1.0 in preview-space coordinates — paint with the overlay widget).
class BoundingBox {
  final double x;       // 0..1 (left)
  final double y;       // 0..1 (top)
  final double w;       // 0..1 (width)
  final double h;       // 0..1 (height)
  final String label;   // "cup", "bottle", "person", etc.
  final double confidence; // 0..1

  const BoundingBox({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.label,
    required this.confidence,
  });

  Rect toRect(Size size) => Rect.fromLTWH(x * size.width, y * size.height,
      w * size.width, h * size.height);

  /// Center point in normalized coordinates.
  Offset get center => Offset(x + w / 2, y + h / 2);

  /// True if the given normalized point falls inside this box.
  bool containsPoint(double px, double py) =>
      px >= x && px <= x + w && py >= y && py <= y + h;

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'w': w, 'h': h,
    'label': label, 'confidence': confidence};

  @override
  String toString() => 'BoundingBox($label @ ($x,$y)-($w,$h) conf=$confidence)';
}
