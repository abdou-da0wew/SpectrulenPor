import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart' show CameraController, FlashMode;

import 'phone_camera_service.dart';

/// Native torch control — uses Android's CameraManager.setTorchMode via a
/// MethodChannel, so the LED STAYS ON even while the camera is streaming.
///
/// The Flutter `camera` plugin's `setFlashMode(FlashMode.torch)` is meant
/// for still-capture flash, not continuous torch — and it gets ignored
/// during an active `startImageStream`. Our native channel fixes that.
///
/// Call `FlashlightService.instance.setTorch(true)` to turn the LED on.
class FlashlightService {
  FlashlightService._();
  static final FlashlightService instance = FlashlightService._();

  static const MethodChannel _channel =
      MethodChannel('com.spectraglass/flashlight');

  bool _on = false;
  bool get isOn => _on;

  /// Turn the torch ON or OFF.
  ///
  /// Returns true if the requested state was successfully applied. If the
  /// native channel isn't wired (e.g. running on web or older Android
  /// without flash), falls back to the camera plugin's FlashMode.torch.
  Future<bool> setTorch(bool on) async {
    if (_on == on) return true;
    try {
      final ok = await _channel.invokeMethod<bool>(on ? 'torch_on' : 'torch_off');
      if (ok == true) {
        _on = on;
        return true;
      }
    } on MissingPluginException {
      debugPrint('[Flashlight] native channel not registered — '
          'falling back to camera plugin FlashMode.');
    } catch (e) {
      debugPrint('[Flashlight] native torch failed: $e — '
          'falling back to camera plugin FlashMode.');
    }

    // Fallback: ask the active PhoneCameraService to apply FlashMode.torch.
    // This works on devices that DO honor the camera plugin's torch during
    // streaming (varies by OEM). Native path above is preferred.
    try {
      final cam = PhoneCameraService.instance;
      await cam.applyCameraFlashMode(on ? FlashMode.torch : FlashMode.off);
      _on = on;
      return true;
    } catch (e) {
      debugPrint('[Flashlight] camera-flash fallback also failed: $e');
      return false;
    }
  }

  /// Refresh cached state by querying native side.
  Future<bool> refresh() async {
    try {
      final v = await _channel.invokeMethod<bool>('is_on');
      _on = v == true;
    } catch (_) {}
    return _on;
  }
}
