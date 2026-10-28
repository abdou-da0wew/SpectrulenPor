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

/// Runs OFF the UI thread: YUV420 (or other) -> RGB -> rotate -> JPEG.
Uint8List? _encodeIsolate(_EncodeArgs a) {
  try {
    img.Image rgb;

    switch (a.formatGroup) {
      case 'yuv420':
      case 'yuv420kp':
        final y = a.planes[0];
        final u = a.planes[1];
        final v = a.planes[2];
        final yRow = a.bytesPerRow[0];
        final uRow = a.bytesPerRow[1];
        final vRow = a.bytesPerRow[2];

        rgb = img.Image(width: a.width, height: a.height);
        for (var py = 0; py < a.height; py++) {
          for (var px = 0; px < a.width; px++) {
            final yi = py * yRow + px;
            final ui = (py >> 1) * uRow + (px >> 1);
            final vi = (py >> 1) * vRow + (px >> 1);

            final Y = y[yi].toDouble();
            final U = u[ui].toDouble() - 128.0;
            final V = v[vi].toDouble() - 128.0;

            final r = (Y + 1.402 * V).round().clamp(0, 255);
            final g =
                (Y - 0.344136 * U - 0.714136 * V).round().clamp(0, 255);
            final b = (Y + 1.772 * U).round().clamp(0, 255);
            rgb.setPixelRgb(px, py, r, g, b);
          }
        }
        break;

      case 'bgra8888':
        rgb = img.Image.fromBytes(
          width: a.width,
          height: a.height,
          bytes: a.planes[0].buffer,
          numChannels: 4,
        );
        break;

      default:
        // Unknown format — decode luma as grayscale; classifier + OCR still
        // work acceptably until the format is mapped.
        rgb = img.Image.fromBytes(
          width: a.width,
          height: a.height,
          bytes: a.planes[0].buffer,
          numChannels: 1,
        );
    }

    if (a.quarterTurns % 4 != 0) {
      rgb = img.copyRotate(rgb, angle: 90 * (a.quarterTurns % 4));
    }

    return Uint8List.fromList(img.encodeJpg(rgb, quality: 82));
  } catch (e) {
    debugPrint('[PhoneCamera] isolate encode failed: $e');
    return null;
  }
}
