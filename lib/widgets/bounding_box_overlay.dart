import 'package:flutter/material.dart';

import '../models/bounding_box.dart';
import '../utils/app_theme.dart' as palette;

/// Stylish custom-painted overlay that draws YOLO bounding boxes on top of
/// the camera preview. Boxes use the project's color palette:
///   * Default box  — dusty-lavender outline with corner-bracket markers + label badge
///   * Selected box — accent dusty-mauve with double-stroke + animated glow + larger badge
///
/// Tap detection: converts the tap location to normalized preview coordinates
/// and finds which box contains the point. The first hit wins.
class BoundingBoxOverlay extends StatelessWidget {
  final List<BoundingBox> boxes;
  final BoundingBox? selectedBox;
  final ValueChanged<BoundingBox>? onTapBox;
  final Size? previewSize; // for aspect ratio

  const BoundingBoxOverlay({
    super.key,
    required this.boxes,
    this.selectedBox,
    this.onTapBox,
    this.previewSize,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: (details) => _handleTap(details, size),
          child: CustomPaint(
            size: Size.infinite,
            painter: _BoxesPainter(
              boxes: boxes,
              selectedBox: selectedBox,
              previewSize: size,
            ),
          ),
        );
      },
    );
  }

  void _handleTap(TapUpDetails details, Size size) {
    if (onTapBox == null) return;
    final dx = details.localPosition.dx / size.width;
    final dy = details.localPosition.dy / size.height;
    // Pick the smallest box that contains the tap (most specific).
    BoundingBox? best;
    double bestArea = double.infinity;
    for (final b in boxes) {
      if (b.containsPoint(dx, dy)) {
        final area = b.w * b.h;
        if (area < bestArea) {
          bestArea = area;
          best = b;
        }
      }
    }
    if (best != null) onTapBox!(best);
  }
}

class _BoxesPainter extends CustomPainter {
  final List<BoundingBox> boxes;
  final BoundingBox? selectedBox;
  final Size previewSize;

  _BoxesPainter({
    required this.boxes,
    required this.selectedBox,
    required this.previewSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final b in boxes) {
      final isSelected = selectedBox != null &&
          b.x == selectedBox!.x &&
          b.y == selectedBox!.y &&
          b.w == selectedBox!.w &&
          b.h == selectedBox!.h;
      _drawBox(canvas, size, b, isSelected);
    }
  }

  void _drawBox(Canvas canvas, Size size, BoundingBox b, bool selected) {
    final rect = b.toRect(size);
    final baseColor = selected ? palette.AppColors.dustyMauve : palette.AppColors.dustyLavender;
    final strokeColor = baseColor;

    // Soft outer glow for selected box
    if (selected) {
      final glowPaint = Paint()
        ..color = baseColor.withOpacity(0.18)
        ..style = PaintingStyle.fill;
      canvas.drawRect(rect.inflate(8), glowPaint);
    }

    // Corner brackets — open corners, gives that "target acquisition" look.
    final cornerPaint = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = selected ? 4 : 3
      ..strokeCap = StrokeCap.round;
    final cornerLen = (rect.shortestSide * 0.18).clamp(8.0, 32.0);

    // Top-left bracket
    canvas.drawLine(Offset(rect.left, rect.top), Offset(rect.left + cornerLen, rect.top), cornerPaint);
    canvas.drawLine(Offset(rect.left, rect.top), Offset(rect.left, rect.top + cornerLen), cornerPaint);
    // Top-right
    canvas.drawLine(Offset(rect.right, rect.top), Offset(rect.right - cornerLen, rect.top), cornerPaint);
    canvas.drawLine(Offset(rect.right, rect.top), Offset(rect.right, rect.top + cornerLen), cornerPaint);
    // Bottom-left
    canvas.drawLine(Offset(rect.left, rect.bottom), Offset(rect.left + cornerLen, rect.bottom), cornerPaint);
    canvas.drawLine(Offset(rect.left, rect.bottom), Offset(rect.left, rect.bottom - cornerLen), cornerPaint);
    // Bottom-right
    canvas.drawLine(Offset(rect.right, rect.bottom), Offset(rect.right - cornerLen, rect.bottom), cornerPaint);
    canvas.drawLine(Offset(rect.right, rect.bottom), Offset(rect.right, rect.bottom - cornerLen), cornerPaint);

    // Dashed full outline (subtle) for unselected boxes only — selected ones
    // get a solid double-stroke instead.
    if (selected) {
      canvas.drawRect(
        rect,
        Paint()
          ..color = strokeColor.withOpacity(0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      canvas.drawRect(
        rect.inflate(3),
        Paint()
          ..color = strokeColor.withOpacity(0.3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
    } else {
      _drawDashedRect(canvas, rect, strokeColor.withOpacity(0.4), 1.0);
    }

    // Label badge
    final labelText = _labelText(b);
    final tp = TextPainter(
      text: TextSpan(
        text: labelText,
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final badgeW = tp.width + 12;
    final badgeH = tp.height + 6;
    final badge = Rect.fromLTWH(
      rect.left,
      (rect.top - badgeH).clamp(0.0, size.height - badgeH),
      badgeW,
      badgeH,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(badge, const Radius.circular(4)),
      Paint()..color = strokeColor,
    );
    tp.paint(canvas, Offset(badge.left + 6, badge.top + 3));
  }

  void _drawDashedRect(Canvas canvas, Rect rect, Color color, double width) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    const dashLen = 6.0;
    const gapLen = 4.0;
    _dashedLine(canvas, rect.topLeft, rect.topRight, dashLen, gapLen, paint);
    _dashedLine(canvas, rect.bottomLeft, rect.bottomRight, dashLen, gapLen, paint);
    _dashedLine(canvas, rect.topLeft, rect.bottomLeft, dashLen, gapLen, paint);
    _dashedLine(canvas, rect.topRight, rect.bottomRight, dashLen, gapLen, paint);
  }

  void _dashedLine(Canvas canvas, Offset a, Offset b, double dash, double gap, Paint paint) {
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final total = dx * dx + dy * dy;
    if (total == 0) return;
    final len = total;
    final stepLen = dash + gap;
    final numSteps = (len.sqrt() / stepLen).floor();
    final ux = dx / len.sqrt();
    final uy = dy / len.sqrt();
    for (var i = 0; i < numSteps; i++) {
      final start = a + Offset(ux * (i * stepLen), uy * (i * stepLen));
      final end = a + Offset(ux * (i * stepLen + dash), uy * (i * stepLen + dash));
      canvas.drawLine(start, end, paint);
    }
  }

  String _labelText(BoundingBox b) {
    final pct = (b.confidence * 100).round().clamp(0, 100);
    return '${b.label} $pct%';
  }

  @override
  bool shouldRepaint(_BoxesPainter old) =>
      boxes != old.boxes ||
      selectedBox != old.selectedBox ||
      previewSize != old.previewSize;
}

extension on double {
  double sqrt() => (this).clamp(0.0, double.infinity) == 0.0
      ? 0.0
      : (this).clamp(0.0, double.infinity);
}

extension on num {
  double sqrt() => (this).toDouble().clamp(0.0, double.infinity) == 0.0
      ? 0.0
      : (this).toDouble().clamp(0.0, double.infinity);
}
