package com.spectraglass.app

import android.content.Context
import android.os.Handler
import android.os.Looper
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
 * posted back to Flutter on the Android main UI thread per @UiThread contract.
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

        @Volatile private var nativeLoaded = false
        private val mainHandler = Handler(Looper.getMainLooper())

        // Loads libmoondream_jni.so (built by CMake, links llama.cpp + clip).
        init {
            try {
                System.loadLibrary("moondream_jni")
                nativeLoaded = true
            } catch (_: UnsatisfiedLinkError) {
                // libmoondream_jni.so not bundled; cloud / ML Kit path will be used.
                nativeLoaded = false
            }
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
                            if (!nativeLoaded) {
                                result.success(null)
                                return@setMethodCallHandler
                            }
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

                            // Heavy work off the platform thread; reply on main thread.
                            Thread {
                                try {
                                    val caption = self.nativeCaption(
                                        modelPath, jpgBytes, prompt, maxTokens
                                    )
                                    mainHandler.post { result.success(caption) }
                                } catch (t: Throwable) {
                                    mainHandler.post {
                                        result.error("inference_error", t.message, null)
                                    }
                                }
                            }.start()
                        }
                        "moondream_unload" -> {
                            if (nativeLoaded) {
                                Thread {
                                    try { self.nativeUnload() } catch (_: Throwable) {}
                                }.start()
                            }
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                }
        }
    }
}
