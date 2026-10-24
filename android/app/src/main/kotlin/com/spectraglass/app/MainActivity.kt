package com.spectraglass.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * SpectruLenPor main activity.
 *
 * Registers:
 *   * MoondreamChannel — native llama.cpp vision engine ("com.spectraglass/llama")
 *
 * NOTE on package name: when you run `flutter create .` to generate the full
 * android/ folder, set the applicationId to com.spectraglass.app (or move this
 * file to match your package). The Dart MethodChannel name
 * "com.spectraglass/llama" is independent of the package name — only this
 * file's location must match the Kotlin package declaration.
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MoondreamChannel.register(flutterEngine, applicationContext)
    }
}
