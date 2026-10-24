package com.spectraglass.app

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * SpectruLenPor — Moondream2 platform channel.
 *
 * Exposes the native llama.cpp + mmproj vision engine to Dart through
 * `com.spectraglass/llama`:
 *
 *   moondream_caption(modelPath, jpgBytes, prompt, maxTokens) -> String?
 *   moondream_unload() -> Boolean
 *
 * Threading: inference runs on a dedicated background thread; the result is
 * delivered back to Flutter by the MethodChannel (thread-safe success/error).
 *
 * Build: see README "Moondream native build" — requires llama.cpp sources
 * under android/app/src/main/cpp/llama.cpp and the CMake target wired in
 * app/build.gradle (reference file next to this folder).
 */
class MoondreamChannel private constructor() {

    private external fun nativeCaption(
        modelPath: String,
        jpgBytes: ByteArray,
        prompt: String,
        maxTokens: Int
    ): String?

    private external fun nativeUnload()

    companion object {
        const val CHANNEL = "com.spectraglass/llama"

        // Loads libmoondream_jni.so (built by CMake, links llama.cpp + clip).
        init {
            try { try { System.loadLibrary("moondream_jni") } catch (e: UnsatisfiedLinkError) { /* libmoondream_jni.so not bundled; cloud path used */ } } catch (e: UnsatisfiedLinkError) { /* libmoondream_jni.so not bundled; cloud path will be used. */ }
        }

        @Volatile private var engineInstance: MoondreamChannel? = null

        /** Call once from MainActivity.configureFlutterEngine(). */
        fun register(engine: FlutterEngine, @Suppress("UNUSED_PARAMETER") appContext: Context) {
            if (engineInstance == null) engineInstance = MoondreamChannel()
            val self = engineInstance!!

            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "moondream_caption" -> {
                            val modelPath = call.argument<String>("modelPath")
                            val jpgBytes = call.argument<ByteArray>("jpgBytes")
                            val prompt = call.argument<String>("prompt")
                                ?: "Describe this image in one short sentence."
                            val maxTokens = call.argument<Int>("maxTokens") ?: 48

                            if (modelPath.isNullOrBlank() || jpgBytes == null) {
                                result.error(
                                    "bad_args", "modelPath/jpgBytes required", null
                                )
                                return@setMethodCallHandler
                            }

                            // Heavy work off the platform thread.
                            Thread {
                                try {
                                    val caption = self.nativeCaption(
                                        modelPath, jpgBytes, prompt, maxTokens
                                    )
                                    result.success(caption)
                                } catch (t: Throwable) {
                                    result.error("inference_error", t.message, null)
                                }
                            }.start()
                        }
                        "moondream_unload" -> {
                            Thread { self.nativeUnload() }.start()
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                }
        }
    }
}
