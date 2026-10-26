import 'package:camera/camera.dart' show FlashMode;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'phone_camera_service.dart';

/// v4.0 hardened flashlight service — multi-strategy fallback for the
/// Android 12/13 tablet case where CameraManager.setTorchMode() returns
/// CAMERA_IN_USE because the Flutter camera plugin holds the camera stream.
///
/// Strategy order:
///   1. Try native CameraManager.setTorchMode() (via FlashlightChannel) on
///      ALL cameras with flash (back, front, external). On most phones this
///      works while the camera is streaming — the OS allows torch + capture
///      on the same camera.
///   2. If 1 returns false (all cameras failed) OR the channel is missing,
///      fall back to the Flutter camera plugin's setFlashMode(FlashMode.torch).
///      This DOES work during streaming on most Samsung / Google / Xiaomi
///      devices — it integrates with the active CaptureRequest.
///   3. If 2 also fails, return false. UI will show "Flashlight unavailable".
class FlashlightService {
  FlashlightService._();
  static final FlashlightService instance = FlashlightService._();

  static const MethodChannel _channel =
      MethodChannel('com.spectraglass/flashlight');

  bool _on = false;
  bool get isOn => _on;

  Future<bool> setTorch(bool on) async {
    if (_on == on) return true;

    // Strategy 1: native CameraManager.
    var nativeOk = false;
    try {
      final ok = await _channel.invokeMethod<bool>(on ? 'torch_on' : 'torch_off');
      nativeOk = ok == true;
    } on MissingPluginException {
      debugPrint('[Flashlight] native channel not registered — trying fallback.');
    } catch (e) {
      debugPrint('[Flashlight] native torch failed: $e — trying fallback.');
    }

    if (nativeOk) {
      _on = on;
      return true;
    }

    // Strategy 2: Flutter camera plugin FlashMode.torch.
    // This works during active streaming on most devices (the camera plugin
    // applies the torch as a CaptureRequest key, which integrates with the
    // active session — unlike what some StackOverflow answers claim).
    try {
      final cam = PhoneCameraService.instance;
      await cam.applyCameraFlashMode(on ? FlashMode.torch : FlashMode.off);
      _on = on;
      debugPrint('[Flashlight] used camera-plugin FlashMode fallback (native returned $nativeOk)');
      return true;
    } catch (e) {
      debugPrint('[Flashlight] camera-flash fallback also failed: $e');
    }

    // Strategy 3: nothing worked.
    _on = false;
    return false;
  }

  Future<bool> refresh() async {
    try {
      final v = await _channel.invokeMethod<bool>('is_on');
      _on = v == true;
    } catch (_) {}
    return _on;
  }

  /// Debug: list cameras with flash (for troubleshooting on tablets).
  Future<List<String>> listFlashCameras() async {
    try {
      final v = await _channel.invokeMethod<List<dynamic>>('list_cameras_with_flash');
      return v?.map((e) => e.toString()).toList() ?? const [];
    } catch (_) {
      return const [];
    }
  }
}
