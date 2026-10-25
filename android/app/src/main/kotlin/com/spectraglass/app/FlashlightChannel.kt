package com.spectraglass.app

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * SpectruLenPor — Native torch control channel.
 *
 * Exposes Android's CameraManager.setTorchMode() to Dart through
 * `com.spectraglass/flashlight`:
 *
 *   torch_on()   -> Boolean   (true if LED successfully turned on)
 *   torch_off()  -> Boolean   (true if LED successfully turned off)
 *   is_on()      -> Boolean   (cached state — no torch query API)
 *
 * Why a native channel instead of the Flutter `camera` plugin's
 * `setFlashMode(FlashMode.torch)`? Because Flutter's FlashMode.torch is a
 * still-capture hint — it's ignored while `startImageStream` is running,
 * which is exactly when SpectruLenPor needs the LED on (auto-flashlight
 * during low-light analysis). CameraManager.setTorchMode() works
 * independently of any active capture session.
 *
 * The torch state survives across config changes (rotation etc.) because
 * Android holds it at the system level until another app turns it off.
 */
class FlashlightChannel private constructor() {

    companion object {
        const val CHANNEL = "com.spectraglass/flashlight"

        @Volatile private var torchOn = false
        @Volatile private var cameraId: String? = null

        /** Register the MethodChannel handler. Call once from
         *  MainActivity.configureFlutterEngine(). */
        fun register(engine: FlutterEngine, context: Context) {
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "torch_on" -> enableTorch(context, result)
                        "torch_off" -> disableTorch(context, result)
                        "is_on" -> result.success(torchOn)
                        else -> result.notImplemented()
                    }
                }
        }

        private fun enableTorch(context: Context, result: MethodChannel.Result) {
            try {
                val cm = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
                if (cameraId == null) {
                    // Pick the back-facing camera that has a flash unit.
                    for (id in cm.cameraIdList) {
                        val ch = cm.getCameraCharacteristics(id)
                        val hasFlash = ch.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) as? Boolean ?: false
                        val facing = ch.get(CameraCharacteristics.LENS_FACING) as? Int
                        if (hasFlash && facing == CameraCharacteristics.LENS_FACING_BACK) {
                            cameraId = id
                            break
                        }
                    }
                }
                val id = cameraId
                if (id == null) {
                    result.error("no_flash", "No back-facing camera with flash available on this device", null)
                    return
                }
                cm.setTorchMode(id, true)
                torchOn = true
                result.success(true)
            } catch (e: Exception) {
                result.error("torch_failed", "torch_on error: ${e.message}", null)
            }
        }

        private fun disableTorch(context: Context, result: MethodChannel.Result) {
            try {
                if (cameraId == null) {
                    // Nothing was ever turned on — treat as success.
                    torchOn = false
                    result.success(true)
                    return
                }
                val cm = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
                cm.setTorchMode(cameraId!!, false)
                torchOn = false
                result.success(true)
            } catch (e: Exception) {
                result.error("torch_failed", "torch_off error: ${e.message}", null)
            }
        }
    }
}
