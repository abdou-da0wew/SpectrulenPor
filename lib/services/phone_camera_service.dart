import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../models/frame_data.dart';
import 'flashlight_service.dart';

/// Live phone-camera source so the app **works today without the glasses**.
///
/// The camera plugin streams YUV420 planes; we convert the latest frame to a
/// JPEG (same contract as the BLE path) inside a background isolate, so both
/// sources — ESP32-CAM glasses and phone camera — feed one identical
/// `FrameData` pipeline downstream.
///
/// Latency notes:
///   * sensor frames arrive at ~30fps; we keep only the newest plane set and
///     encode at most one frame at a time (stale work is dropped).
///   * preview uses the native `CameraPreview` texture (zero-copy), so the
///     heavy YUV->JPEG path only runs at the analysis cadence (1-2 fps).
class PhoneCameraService {
  PhoneCameraService();
  static final PhoneCameraService instance = PhoneCameraService();

  CameraController? _controller;
  bool _streaming = false;
  bool _encoding = false;
  int _quarterTurns = 1; // most Android sensors are 90° CW in portrait

  /// 0 = none, 1 = 90°, 2 = 180°, 3 = 270°. Adjust in Settings if the
  /// analysis frame looks sideways on your device.
  int get quarterTurns => _quarterTurns;
  set quarterTurns(int v) => _quarterTurns = v.clamp(0, 3);

  CameraController? get controller => _controller;
  bool get isStreaming => _streaming;

  /// Logical portrait-oriented preview dimensions matching the encoded JPEG.
  Size? get previewLogicalSize {
    final ps = _controller?.value.previewSize;
    if (ps == null) return null;
    final rotated = (_quarterTurns % 2) == 1;
    return rotated ? Size(ps.height, ps.width) : Size(ps.width, ps.height);
  }

  final StreamController<FrameData> _frameCtl =
      StreamController<FrameData>.broadcast();
  Stream<FrameData> get frameStream => _frameCtl.stream;

  Future<void> start(
      {ResolutionPreset preset = ResolutionPreset.high}) async {
    if (_streaming) return;
    final cameras = await availableCameras();
    if (cameras.isEmpty) throw 'No camera found on this device.';
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    final ctrl = CameraController(back, preset, enableAudio: false);
    await ctrl.initialize();
    await ctrl.lockCaptureOrientation(DeviceOrientation.portraitUp);
    _controller = ctrl;

    await ctrl.startImageStream(_onCameraImage);
    _streaming = true;
    debugPrint('[PhoneCamera] live — ${ctrl.value.previewSize}');
  }

  int _sequence = 0;

  void _onCameraImage(CameraImage image) {
    if (_encoding) return; // one encode in flight — drop stale frames
    _encoding = true;

    final args = _EncodeArgs(
      planes: image.planes
          .map((p) => Uint8List.fromList(p.bytes))
          .toList(growable: false),
      bytesPerRow: image.planes.map((p) => p.bytesPerRow).toList(growable: false),
      width: image.width,
      height: image.height,
      formatGroup: image.format.group.name,
      quarterTurns: _quarterTurns,
      sequence: ++_sequence,
    );

    compute(_encodeIsolate, args).then((jpeg) {
      _encoding = false;
      if (jpeg == null) return;
      final rotated = (args.quarterTurns % 2) == 1;
      _frameCtl.add(FrameData(
        jpegBytes: jpeg,
        width: rotated ? args.height : args.width,
        height: rotated ? args.width : args.height,
        capturedAt: DateTime.now(),
      ));
    }).catchError((e) {
      _encoding = false;
      debugPrint('[PhoneCamera] encode error: $e');
    });
  }

  Future<void> stop() async {
    _streaming = false;
    try {
      await _controller?.stopImageStream();
      await _controller?.dispose();
    } catch (_) {}
    _controller = null;
  }

  /// Camera-plugin FlashMode fallback. Used by [FlashlightService] when the
  /// native CameraManager path fails (some OEMs lock torch during video
  /// capture). This sets the capture flash mode — applies to subsequent
  /// stills, NOT to the streaming torch — but it's the best fallback we
  /// have for devices where native torch is restricted.
  Future<void> applyCameraFlashMode(FlashMode mode) async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    await ctrl.setFlashMode(mode);
  }

  /// Public torch toggle — RecognitionState calls this directly. Delegates
  /// to [FlashlightService] which uses the native CameraManager.setTorchMode
  /// path (works WHILE streaming, unlike the camera plugin's FlashMode.torch).
  /// Returns true if the requested state was successfully applied.
  Future<bool> setTorch(bool on) async {
    // Avoid circular import at the file level — do the import lazily.
    return await FlashlightService.instance.setTorch(on);
  }

  void dispose() => stop();
}

/// Immutable arg bundle passed to the background isolate.
class _EncodeArgs {
  final List<Uint8List> planes;
  final List<int> bytesPerRow;
  final int width, height, quarterTurns, sequence;
  final String formatGroup;

  const _EncodeArgs({
    required this.planes,
    required this.bytesPerRow,
    required this.width,
    required this.height,
    required this.formatGroup,
    required this.quarterTurns,
    required this.sequence,
  });
}

/// Fixed-point BT.601 YUV weights (×1024, rounding pre-added) — integer math
/// is ~2x faster than doubles in the hot per-pixel loop.
const int _kvR = 1 << 10; // Y coeff for R is 1.000
const int _kvG0 = 376; // -0.344136 * 1024, negated below
const int _kvG1 = 731; // -0.714136 * 1024, negated below
const int _kvU = 1814; // 1.772 * 1024
const int _kvV = 1435; // 1.402 * 1024

/// NV21 chroma stride. The camera plugin's [Plane] doesn't expose
/// [ImagePlane.pixelStride], but Camera2 YUV_420_888 is NV21-interleaved
/// (VU pairs) on virtually every Android device, so chroma samples sit 2
/// bytes apart and each plane's buffer starts at its first U/V byte.
const int _kChromaStride = 2;

/// Runs OFF the UI thread: YUV420 -> RGB -> rotate -> JPEG.
///
/// * Chroma must be indexed with each plane's own [pixelStride]: Android's
///   YUV_420_888 almost always interleaves U/V with pixelStride = 2. Treating
///   the plane as dense (stride 1) scrambles chroma and renders the frame
///   grayscale/hue-noisy.
/// * Rotation is folded into the destination write so one pass produces the
///   final portrait frame (no second `copyRotate` pass).
/// * A flat RGB byte buffer + [img.Image.fromBytes] avoids per-pixel
///   [img.Image] object overhead.
Uint8List? _encodeIsolate(_EncodeArgs a) {
  try {
    final int w = a.width;
    final int h = a.height;
    final bool swapped = (a.quarterTurns % 2) == 1;
    final int outW = swapped ? h : w;
    final int outH = swapped ? w : h;
    final int quarter = a.quarterTurns % 4;

    Uint8List rgbBuf;
    switch (a.formatGroup) {
      case 'yuv420':
      case 'yuv420kp':
        {
          final y = a.planes[0];
          final u = a.planes[1];
          final v = a.planes[2];
          final yRow = a.bytesPerRow[0];
          final uRow = a.bytesPerRow[1];
          final vRow = a.bytesPerRow[2];
          final yLen = y.length;
          final uLen = u.length;
          final vLen = v.length;

          rgbBuf = Uint8List(outW * outH * 3);
          for (var py = 0; py < h; py++) {
            final yRowBase = py * yRow;
            final chromaRow = (py >> 1) * uRow;
            final chromaRowV = (py >> 1) * vRow;
            for (var px = 0; px < w; px++) {
              var yi = yRowBase + px;
              if (yi >= yLen) yi = yLen - 1;
              var ui = chromaRow + (px >> 1) * _kChromaStride;
              if (ui >= uLen) ui = uLen - 1;
              var vi = chromaRowV + (px >> 1) * _kChromaStride;
              if (vi >= vLen) vi = vLen - 1;

              final int Y = y[yi];
              final int U = u[ui] - 128;
              final int V = v[vi] - 128;

              final int yy = Y << 10;
              int r = (yy + _kvV * V + 512) >> 10;
              int g =
                  (yy - _kvG0 * U - _kvG1 * V + 512) >> 10;
              int b = (yy + _kvU * U + 512) >> 10;
              if (r < 0) r = 0;
              if (r > 255) r = 255;
              if (g < 0) g = 0;
              if (g > 255) g = 255;
              if (b < 0) b = 0;
              if (b > 255) b = 255;

              int dx;
              int dy;
              switch (quarter) {
                case 1:
                  dx = h - 1 - py;
                  dy = px;
                  break;
                case 2:
                  dx = w - 1 - px;
                  dy = h - 1 - py;
                  break;
                case 3:
                  dx = py;
                  dy = w - 1 - px;
                  break;
                default:
                  dx = px;
                  dy = py;
              }
              final int dIndex = (dy * outW + dx) * 3;
              rgbBuf[dIndex] = r;
              rgbBuf[dIndex + 1] = g;
              rgbBuf[dIndex + 2] = b;
            }
          }
        }
        break;

      case 'bgra8888':
        return Uint8List.fromList(
          img.encodeJpg(
            _maybeRotate(
              img.Image.fromBytes(
                width: w,
                height: h,
                bytes: a.planes[0].buffer,
                numChannels: 4,
                order: img.ChannelOrder.bgra,
              ),
              quarter,
            ),
            quality: 82,
          ),
        );

      default:
        // Unknown format — decode luma as grayscale; classifier + OCR still
        // work acceptably until the format is mapped.
        final gray = img.Image.fromBytes(
          width: w,
          height: h,
          bytes: a.planes[0].buffer,
          numChannels: 1,
        );
        return Uint8List.fromList(
            img.encodeJpg(_maybeRotate(gray, quarter), quality: 82));
    }

    final rgb = img.Image.fromBytes(
      width: outW,
      height: outH,
      bytes: rgbBuf.buffer,
      numChannels: 3,
      order: img.ChannelOrder.rgb,
    );
    return Uint8List.fromList(img.encodeJpg(rgb, quality: 82));
  } catch (e) {
    debugPrint('[PhoneCamera] isolate encode failed: $e');
    return null;
  }
}

/// Rotates an already-converted frame for paths that could not fold
/// rotation into the pixel loop (BGRA / grayscale branches).
img.Image _maybeRotate(img.Image image, int quarter) {
  if (quarter == 0) return image;
  return img.copyRotate(image, angle: 90 * quarter);
}
