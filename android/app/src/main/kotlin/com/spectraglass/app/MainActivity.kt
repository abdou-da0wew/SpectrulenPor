package com.spectraglass.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * SpectruLenPor main activity (v5.4).
 *
 * Registers:
 *   * AppDatabaseChannel   — native SQLite WAL internal DB ("com.spectraglass/db")
 *   * MoondreamChannel     — native llama.cpp vision engine ("com.spectraglass/llama")
 *   * FlashlightChannel    — Android CameraManager torch ("com.spectraglass/flashlight")
 *   * YoloInferenceChannel — ONNX Runtime YOLO26-Nano ("com.spectraglass/yolo")
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AppDatabaseChannel.register(flutterEngine, applicationContext)
        MoondreamChannel.register(flutterEngine, applicationContext)
        FlashlightChannel.register(flutterEngine, applicationContext)
        YoloInferenceChannel.register(flutterEngine, applicationContext)
    }
}
