package com.spectraglass.app

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * SpectruLenPor — Native torch control channel (v4: hardened for Android 12-17 tablets).
 *
 * Multi-strategy approach to handle different OEM quirks:
 *   Strategy 1: CameraManager.setTorchMode() — preferred, works WHEN no other
 *                app holds the camera. Some tablets fail this with CAMERA_IN_USE
 *                when the Flutter camera plugin is actively streaming.
 *   Strategy 2: Try ALL cameras (front + back + external) with flash. Some
 *                tablets (e.g. Lenovo Tab P12) have the flash unit on an
 *                unexpected cameraId.
 *   Strategy 3: If 1+2 fail, return false — Dart side then falls back to
 *                the Flutter camera plugin's setFlashMode(FlashMode.torch),
 *                which DOES integrate with the active stream on most devices.
 *
 * Exposes:
 *   torch_on()   -> Boolean   (true if any strategy succeeded)
 *   torch_off()  -> Boolean
 *   is_on()      -> Boolean   (cached)
 *   list_cameras_with_flash() -> List<String>   (for debugging)
 */
class FlashlightChannel private constructor() {

    companion object {
        const val CHANNEL = "com.spectraglass/flashlight"

        @Volatile private var torchOn = false
        @Volatile private var activeCameraId: String? = null
        @Volatile private var flashCameraIds: List<String> = emptyList()

        fun register(engine: FlutterEngine, context: Context) {
            // Pre-enumerate flash cameras once.
            refreshFlashCameraIds(context)

            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "torch_on" -> enableTorch(context, result)
                        "torch_off" -> disableTorch(context, result)
                        "is_on" -> result.success(torchOn)
                        "list_cameras_with_flash" -> result.success(flashCameraIds)
                        else -> result.notImplemented()
                    }
                }
        }

        private fun refreshFlashCameraIds(context: Context) {
            try {
                val cm = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
                val ids = mutableListOf<String>()
                for (id in cm.cameraIdList) {
                    val ch = cm.getCameraCharacteristics(id)
                    val hasFlash = ch.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) as? Boolean ?: false
                    if (hasFlash) ids.add(id)
                }
                flashCameraIds = ids
                // Default to the back-facing one if present, else first.
                activeCameraId = ids.firstOrNull { id ->
                    val facing = cm.getCameraCharacteristics(id)
                        .get(CameraCharacteristics.LENS_FACING) as? Int
                    facing == CameraCharacteristics.LENS_FACING_BACK
                } ?: ids.firstOrNull()
            } catch (e: Exception) {
                flashCameraIds = emptyList()
            }
        }

        private fun enableTorch(context: Context, result: MethodChannel.Result) {
            try {
                if (flashCameraIds.isEmpty()) refreshFlashCameraIds(context)
                if (flashCameraIds.isEmpty()) {
                    result.error("no_flash", "No camera with flash unit available on this device", null)
                    return
                }
                val cm = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
                // Strategy 1: try the preferred (back-facing) camera.
                var succeeded = false
                val errors = mutableListOf<String>()
                for (id in flashCameraIds) {
                    try {
                        cm.setTorchMode(id, true)
                        activeCameraId = id
                        torchOn = true
                        succeeded = true
                        break
                    } catch (e: Exception) {
                        errors.add("$id: ${e.message}")
                        // Continue to next camera — this one might be in use
                        // or restricted by another app.
                    }
                }
                if (succeeded) {
                    result.success(true)
                } else {
                    // All cameras failed — return false so Dart falls back to
                    // the Flutter camera plugin's FlashMode.torch.
                    result.success(false)
                }
            } catch (e: Exception) {
                result.error("torch_failed", "torch_on error: ${e.message}", null)
            }
        }

        private fun disableTorch(context: Context, result: MethodChannel.Result) {
            try {
                if (activeCameraId == null) {
                    torchOn = false
                    result.success(true)
                    return
                }
                val cm = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
                cm.setTorchMode(activeCameraId!!, false)
                torchOn = false
                result.success(true)
            } catch (e: Exception) {
                // Even if disable fails (e.g. camera released), mark as off.
                torchOn = false
                result.success(true)
            }
        }
    }
}
