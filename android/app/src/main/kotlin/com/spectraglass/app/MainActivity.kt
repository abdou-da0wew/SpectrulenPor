package com.spectraglass.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * SpectruLenPor main activity.
 *
 * Registers:
 *   * MoondreamChannel — native llama.cpp vision engine ("com.spectraglass/llama")
 *   * FlashlightChannel — Android CameraManager torch ("com.spectraglass/flashlight")
 *
 * The Dart MethodChannel names are independent of the Kotlin package name —
 * only the file's location must match the Kotlin package declaration.
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MoondreamChannel.register(flutterEngine, applicationContext)
        FlashlightChannel.register(flutterEngine, applicationContext)
    }
}
