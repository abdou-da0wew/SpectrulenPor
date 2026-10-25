import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Result of the vision gate's heuristic checks on a frame.
///
/// The gate runs BEFORE any expensive vision model call (cloud Moondream /
/// local Moondream / ONNX). If [visible] is false, the pipeline MUST skip
/// the model call and stay idle — we don't burn API quota on pitch-dark,
/// blocked, blank, or motion-blurred frames.
class VisionGateResult {
  final bool visible;
  final double brightness;       // 0..255 mean luminance (Rec. 709)
  final double variance;         // 0..255 std-dev of luminance (blank check)
  final double blurScore;        // Laplacian variance (low = blurred)
  final bool blocked;            // lens is covered (dark + uniform)
  final String reason;           // 'ok' | 'too_dark' | 'blank' | 'blurred' | 'blocked' | 'decode_failed'

  const VisionGateResult({
    required this.visible,
    required this.brightness,
    required this.variance,
    required this.blurScore,
    required this.blocked,
    required this.reason,
  });

  bool get tooDark => brightness < kMinBrightness;
  bool get tooBlank => variance < kMinVariance;
  bool get tooBlurred => blurScore < kMinBlurScore;

  static const double kMinBrightness = 38;  // ~15% luma — anything darker = pitch dark
  static const double kMinVariance   = 22;  // ~9% std-dev — anything flatter = blank wall
  static const double kMinBlurScore   = 45; // Laplacian-var — anything lower = motion blur

  @override
  String toString() =>
      'VisionGate(visible=$visible, brightness=${brightness.toStringAsFixed(1)}, '
      'variance=${variance.toStringAsFixed(1)}, blur=${blurScore.toStringAsFixed(1)}, '
      'blocked=$blocked, reason=$reason)';
}

/// Lightweight, model-free pre-filter that decides whether a frame is worth
/// sending to a vision model.
///
/// Uses a 64x64 downscaled luma plane (cheap — runs in a background isolate):
///   * **brightness** — mean of Rec. 709 luma. Lens covered or no light =
///     very low value.
///   * **variance** — std-dev of luma. Flat single-color frame (lens cap,
///     table, ceiling) = near zero.
///   * **blurScore** — Laplacian variance. Motion blur or out-of-focus =
///     low value (sharp edges produce high Laplacian response).
///   * **blocked** — heuristic: very dark AND very flat = lens is covered.
class VisionGate {
  /// Run the gate on a JPEG. Returns a [VisionGateResult].
  ///
  /// Runs in a background isolate — never blocks the UI thread. Decoding +
  /// downsampling + the 3 heuristics together take ~3-8 ms on a modern phone
  /// for a 640x480 JPEG.
  static Future<VisionGateResult> check(Uint8List jpegBytes) async {
    try {
      return await compute(_analyze, jpegBytes);
    } catch (e) {
      debugPrint('[VisionGate] analyze failed: $e');
      return const VisionGateResult(
        visible: false,
        brightness: 0,
        variance: 0,
        blurScore: 0,
        blocked: true,
        reason: 'decode_failed',
      );
    }
  }

  static VisionGateResult _analyze(Uint8List jpegBytes) {
    final decoded = img.decodeImage(jpegBytes);
    if (decoded == null) {
      return const VisionGateResult(
        visible: false,
        brightness: 0,
        variance: 0,
        blurScore: 0,
        blocked: true,
        reason: 'decode_failed',
      );
    }

    // Downsample to 64x64 for O(1) cost regardless of input resolution.
    const w = 64, h = 64;
    final small = img.copyResize(decoded, width: w, height: h,
        interpolation: img.Interpolation.average);

    // Build the luma plane (Rec. 709).
    final lum = Float64List(w * h);
    double sum = 0;
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final p = small.getPixel(x, y);
        final l = 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b;
        lum[y * w + x] = l;
        sum += l;
      }
    }
    final mean = sum / (w * h);

    // Variance (blank / single-color detection).
    double varSum = 0;
    for (final l in lum) {
      varSum += (l - mean) * (l - mean);
    }
    final stdDev = math.sqrt(varSum / (w * h));

    // Laplacian variance (blur detection).
    double lapSum = 0, lapSqSum = 0;
    int n = 0;
    for (int y = 1; y < h - 1; y++) {
      for (int x = 1; x < w - 1; x++) {
        final v = lum[y * w + x];
        // 4-connected discrete Laplacian: |L| = |−4v + N + S + E + W|
        final lap = -4 * v +
            lum[(y - 1) * w + x] +
            lum[(y + 1) * w + x] +
            lum[y * w + (x - 1)] +
            lum[y * w + (x + 1)];
        lapSum += lap;
        lapSqSum += lap * lap;
        n++;
      }
    }
    final lapMean = lapSum / n;
    final lapVar = lapSqSum / n - lapMean * lapMean;

    // Blocked: lens covered with finger / case / pocket — very dark + flat.
    final blocked = mean < 25 && stdDev < 10;

    final tooDark = mean < VisionGateResult.kMinBrightness;
    final tooBlank = stdDev < VisionGateResult.kMinVariance;
    final tooBlurred = lapVar < VisionGateResult.kMinBlurScore;

    String reason;
    if (blocked) reason = 'blocked';
    else if (tooDark) reason = 'too_dark';
    else if (tooBlank) reason = 'blank';
    else if (tooBlurred) reason = 'blurred';
    else reason = 'ok';

    final visible = !tooDark && !tooBlank && !tooBlurred && !blocked;

    return VisionGateResult(
      visible: visible,
      brightness: mean,
      variance: stdDev,
      blurScore: lapVar,
      blocked: blocked,
      reason: reason,
    );
  }
}
