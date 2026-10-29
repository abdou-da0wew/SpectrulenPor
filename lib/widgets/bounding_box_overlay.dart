import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/bounding_box.dart';
import '../utils/app_theme.dart' as palette;

/// Custom-designed interactive YOLO26-Nano bounding box overlay.
///
/// Visual & interaction design:
///   * Unselected boxes render a subtle precision lavender frame with corner
///     ticks and a tappable label pill (`Icons.crop_free_rounded`).
///   * Tapping any box locks onto it with a smooth 260ms easeOutBack animation,
///     rendering a glowing dusty-mauve target frame, bold corner L-brackets,
///     a center crosshair target reticle (`+` inside a target ring), and a
///     prominent `SELECTED · <LABEL> <PCT>%` marker badge.
///   * Tapping the already-selected box clears the selection (`onSelect(null)`).
///   * When [sourceAspectRatio] (`imageWidth / imageHeight`) is supplied alongside
///     a `BoxFit.cover` camera preview, normalized `0..1` coordinates are mapped
///     through the exact same cover scale & center-crop offset so boxes align
///     pixel-for-pixel without shrinking the preview.
class BoundingBoxOverlay extends StatefulWidget {
  final List<BoundingBox> boxes;
  final BoundingBox? selected;
  final ValueChanged<BoundingBox?> onSelect;

  /// Optional upright image aspect ratio (`width / height`) when the underlying
  /// camera preview uses `BoxFit.cover`. When `null`, normalized coordinates map
  /// directly to `[0..maxWidth] x [0..maxHeight]`.
  final double? sourceAspectRatio;

  const BoundingBoxOverlay({
    super.key,
    required this.boxes,
    required this.selected,
    required this.onSelect,
    this.sourceAspectRatio,
  });

  @override
  State<BoundingBoxOverlay> createState() => _BoundingBoxOverlayState();
}

class _BoundingBoxOverlayState extends State<BoundingBoxOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _lockAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1.0,
  );

  @override
  void didUpdateWidget(covariant BoundingBoxOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != null &&
        !_sameBox(oldWidget.selected, widget.selected)) {
      _lockAnim.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _lockAnim.dispose();
    super.dispose();
  }

  static bool _sameBox(BoundingBox? a, BoundingBox? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return a.label == b.label &&
        (a.x - b.x).abs() < 0.04 &&
        (a.y - b.y).abs() < 0.04 &&
        (a.w - b.w).abs() < 0.06 &&
        (a.h - b.h).abs() < 0.06;
  }

  ({double offsetX, double offsetY, double renderedW, double renderedH})
      _coverProjection(double viewW, double viewH) {
    final srcAspect = widget.sourceAspectRatio;
    if (srcAspect == null || srcAspect <= 0 || viewW <= 0 || viewH <= 0) {
      return (
        offsetX: 0.0,
        offsetY: 0.0,
        renderedW: viewW,
        renderedH: viewH,
      );
    }
    final viewAspect = viewW / viewH;
    if (viewAspect > srcAspect) {
      final rw = viewW;
      final rh = viewW / srcAspect;
      return (
        offsetX: 0.0,
        offsetY: (viewH - rh) / 2.0,
        renderedW: rw,
        renderedH: rh,
      );
    } else {
      final rh = viewH;
      final rw = viewH * srcAspect;
      return (
        offsetX: (viewW - rw) / 2.0,
        offsetY: 0.0,
        renderedW: rw,
        renderedH: rh,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        if (!w.isFinite || !h.isFinite || w <= 0 || h <= 0) {
          return const SizedBox.shrink();
        }

        final proj = _coverProjection(w, h);
        final displayBoxes = <BoundingBox>[...widget.boxes];
        if (widget.selected != null &&
            !displayBoxes.any((b) => _sameBox(b, widget.selected))) {
          displayBoxes.add(widget.selected!);
        }

        return AnimatedBuilder(
          animation: _lockAnim,
          builder: (context, _) {
            final lockT = Curves.easeOutBack.transform(_lockAnim.value);
            return Stack(
              clipBehavior: Clip.none,
              children: [
                for (final b in displayBoxes)
                  _buildBoxWidget(
                    b: b,
                    viewW: w,
                    viewH: h,
                    proj: proj,
                    isSelected: _sameBox(widget.selected, b),
                    lockT: lockT,
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildBoxWidget({
    required BoundingBox b,
    required double viewW,
    required double viewH,
    required ({
      double offsetX,
      double offsetY,
      double renderedW,
      double renderedH
    }) proj,
    required bool isSelected,
    required double lockT,
  }) {
    final rawLeft = proj.offsetX + b.x * proj.renderedW;
    final rawTop = proj.offsetY + b.y * proj.renderedH;
    final rawW = b.w * proj.renderedW;
    final rawH = b.h * proj.renderedH;

    final double left = rawLeft.clamp(0.0, math.max(0.0, viewW - 28.0)).toDouble();
    final double top = rawTop.clamp(0.0, math.max(0.0, viewH - 28.0)).toDouble();
    final double boxW = rawW.clamp(28.0, math.max(28.0, viewW - left)).toDouble();
    final double boxH = rawH.clamp(28.0, math.max(28.0, viewH - top)).toDouble();
    final pct = (b.confidence * 100).round().clamp(0, 100);

    // Place badge just above the box when space allows, otherwise inside top-left.
    final badgeAbove = top >= 32.0;

    return Positioned(
      left: left,
      top: top,
      width: boxW,
      height: boxH,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onSelect(isSelected ? null : b),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _TargetBoxPainter(
                  isSelected: isSelected,
                  lockScale: isSelected ? lockT : 1.0,
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: badgeAbove ? -28 : 4,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: math.max(boxW, math.min(220.0, viewW - left)),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    gradient: isSelected
                        ? const LinearGradient(
                            colors: [
                              palette.AppColors.dustyLavender,
                              palette.AppColors.dustyMauve,
                            ],
                          )
                        : null,
                    color: isSelected
                        ? null
                        : palette.AppColors.inkDark.withOpacity(0.82),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected
                          ? Colors.white.withOpacity(0.9)
                          : palette.AppColors.dustyMauve.withOpacity(0.75),
                      width: isSelected ? 1.3 : 1.0,
                    ),
                    boxShadow: isSelected
                        ? [
                            BoxShadow(
                              color:
                                  palette.AppColors.dustyMauve.withOpacity(0.45),
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isSelected
                            ? Icons.gps_fixed_rounded
                            : Icons.crop_free_rounded,
                        size: 13,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          isSelected
                              ? 'SELECTED · ${b.label} $pct%'
                              : '${b.label} $pct%',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight:
                                isSelected ? FontWeight.w800 : FontWeight.w600,
                            letterSpacing: isSelected ? 0.3 : 0.1,
                          ),
                        ),
                      ),
                      if (isSelected) ...[
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.close_rounded,
                          size: 12,
                          color: Colors.white70,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TargetBoxPainter extends CustomPainter {
  final bool isSelected;
  final double lockScale;

  const _TargetBoxPainter({
    required this.isSelected,
    required this.lockScale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(10));

    if (!isSelected) {
      // Subtle translucent wash + clean lavender frame + corner ticks
      final fillPaint = Paint()
        ..color = palette.AppColors.dustyLavender.withOpacity(0.08)
        ..style = PaintingStyle.fill;
      canvas.drawRRect(rrect, fillPaint);

      final borderPaint = Paint()
        ..color = palette.AppColors.dustyMauve.withOpacity(0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6;
      canvas.drawRRect(rrect, borderPaint);

      _drawCornerBrackets(
        canvas,
        size,
        color: Colors.white.withOpacity(0.85),
        strokeWidth: 2.2,
        fraction: 0.16,
      );
      return;
    }

    // Selected object: outer glow + tinted highlight + crisp double border +
    // bold corner brackets + center target reticle marker.
    final glowPaint = Paint()
      ..color = palette.AppColors.dustyMauve.withOpacity(0.42)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    canvas.drawRRect(rrect, glowPaint);

    final fillPaint = Paint()
      ..color = palette.AppColors.dustyMauve.withOpacity(0.16)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(rrect, fillPaint);

    final outerStroke = Paint()
      ..color = palette.AppColors.dustyMauve
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.8;
    canvas.drawRRect(rrect, outerStroke);

    if (size.width > 12 && size.height > 12) {
      final innerRect = RRect.fromRectAndRadius(
        rect.deflate(3.5),
        const Radius.circular(7),
      );
      final innerStroke = Paint()
        ..color = Colors.white.withOpacity(0.75)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawRRect(innerRect, innerStroke);
    }

    _drawCornerBrackets(
      canvas,
      size,
      color: Colors.white,
      strokeWidth: 3.2,
      fraction: 0.24,
    );

    // Center lock-on target marker (ring + crosshair + center dot)
    final center = Offset(size.width / 2, size.height / 2);
    final minDim = math.min(size.width, size.height);
    if (minDim >= 36) {
      final baseRadius = (minDim * 0.12).clamp(8.0, 18.0);
      final radius = baseRadius * (0.75 + 0.25 * lockScale.clamp(0.5, 1.2));

      final ringBg = Paint()
        ..color = palette.AppColors.dustyLavender.withOpacity(0.65)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(center, radius, ringBg);

      final ringStroke = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8;
      canvas.drawCircle(center, radius, ringStroke);

      final tick = radius + 5.0;
      canvas.drawLine(
        Offset(center.dx - tick, center.dy),
        Offset(center.dx - radius * 0.45, center.dy),
        ringStroke,
      );
      canvas.drawLine(
        Offset(center.dx + radius * 0.45, center.dy),
        Offset(center.dx + tick, center.dy),
        ringStroke,
      );
      canvas.drawLine(
        Offset(center.dx, center.dy - tick),
        Offset(center.dx, center.dy - radius * 0.45),
        ringStroke,
      );
      canvas.drawLine(
        Offset(center.dx, center.dy + radius * 0.45),
        Offset(center.dx, center.dy + tick),
        ringStroke,
      );

      final dotPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;
      canvas.drawCircle(center, 2.4, dotPaint);
    }
  }

  void _drawCornerBrackets(
    Canvas canvas,
    Size size, {
    required Color color,
    required double strokeWidth,
    required double fraction,
  }) {
    final len = (math.min(size.width, size.height) * fraction).clamp(7.0, 26.0);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = strokeWidth;

    // Top-left
    canvas.drawLine(const Offset(0, 0), Offset(len, 0), p);
    canvas.drawLine(const Offset(0, 0), Offset(0, len), p);
    // Top-right
    canvas.drawLine(Offset(size.width, 0), Offset(size.width - len, 0), p);
    canvas.drawLine(Offset(size.width, 0), Offset(size.width, len), p);
    // Bottom-left
    canvas.drawLine(Offset(0, size.height), Offset(len, size.height), p);
    canvas.drawLine(Offset(0, size.height), Offset(0, size.height - len), p);
    // Bottom-right
    canvas.drawLine(
      Offset(size.width, size.height),
      Offset(size.width - len, size.height),
      p,
    );
    canvas.drawLine(
      Offset(size.width, size.height),
      Offset(size.width, size.height - len),
      p,
    );
  }

  @override
  bool shouldRepaint(covariant _TargetBoxPainter oldDelegate) =>
      oldDelegate.isSelected != isSelected ||
      (oldDelegate.lockScale - lockScale).abs() > 0.005;
}
