package com.spectraglass.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.RecognitionListener
import org.vosk.android.SpeechService
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.zip.ZipInputStream

/** Offline Vosk model provisioning and 16 kHz microphone recognition. */
object VoskSpeechChannel {
    private const val TAG = "VoskSpeech"
    private const val METHOD_CHANNEL = "spectrulenpor/vosk"
    private const val EVENT_CHANNEL = "spectrulenpor/vosk/events"
    private const val SAMPLE_RATE = 16000.0f
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var model: Model? = null
    @Volatile private var recognizer: Recognizer? = null
    @Volatile private var speechService: SpeechService? = null
    @Volatile private var eventSink: EventChannel.EventSink? = null
    @Volatile private var appContext: Context? = null

    fun register(engine: FlutterEngine, context: Context) {
        appContext = context.applicationContext
        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ensureModel" -> ensureModel(call, result)
                    "loadModel" -> loadModel(call, result)
                    "start" -> start(result)
                    "stop" -> stop(result)
                    "status" -> result.success(
                        mapOf("loaded" to (model != null), "listening" to (speechService != null))
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun ensureModel(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("modelName")?.takeIf { it.matches(Regex("[a-zA-Z0-9._-]+")) }
        val url = call.argument<String>("url")?.takeIf { it.startsWith("https://") }
        val context = appContext
        if (name == null || url == null || context == null) {
            result.error("MODEL_ARGUMENTS_INVALID", "A valid model name and HTTPS URL are required.", null)
            return
        }
        worker.execute {
            try {
                val root = File(context.filesDir, "models/vosk")
                val destination = File(root, name)
                if (isValidModel(destination)) {
                    postSuccess(result, destination.absolutePath)
                    return@execute
                }
                root.mkdirs()
                val archive = File(root, "$name.zip.part")
                val connection = (URL(url).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 20_000
                    readTimeout = 60_000
                    instanceFollowRedirects = true
                    setRequestProperty("User-Agent", "SpectruLenPor/5")
                }
                try {
                    connection.connect()
                    if (connection.responseCode !in 200..299) {
                        throw IllegalStateException("Model download failed: HTTP ${connection.responseCode}")
                    }
                    val total = connection.contentLengthLong
                    var received = 0L
                    BufferedInputStream(connection.inputStream).use { input ->
                        FileOutputStream(archive).use { output ->
                            val buffer = ByteArray(64 * 1024)
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                output.write(buffer, 0, count)
                                received += count
                                emit("download", mapOf("model" to name, "received" to received, "total" to total))
                            }
                        }
                    }
                } finally {
                    connection.disconnect()
                }
                val temporary = File(root, "$name.extracting").apply {
                    deleteRecursively()
                    mkdirs()
                }
                extractSafely(archive, temporary)
                archive.delete()
                val extracted = findModelDirectory(temporary)
                    ?: throw IllegalStateException("The downloaded archive does not contain a valid Vosk model.")
                val staged = File(root, "$name.staged")
                staged.deleteRecursively()
                if (!extracted.renameTo(staged)) {
                    extracted.copyRecursively(staged, overwrite = true)
                }
                temporary.deleteRecursively()
                destination.deleteRecursively()
                if (!staged.renameTo(destination)) {
                    staged.copyRecursively(destination, overwrite = true)
                    staged.deleteRecursively()
                }
                if (!isValidModel(destination)) {
                    destination.deleteRecursively()
                    throw IllegalStateException("Vosk model extraction did not produce a valid model.")
                }
                postSuccess(result, destination.absolutePath)
                emit("modelReady", mapOf("model" to name, "path" to destination.absolutePath))
            } catch (error: Throwable) {
                Log.e(TAG, "Model provisioning failed", error)
                postError(result, "MODEL_DOWNLOAD_FAILED", error.message ?: "Unable to install Vosk model.")
            }
        }
    }

    private fun extractSafely(archive: File, destination: File) {
        val root = destination.canonicalPath + File.separator
        ZipInputStream(BufferedInputStream(archive.inputStream())).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val output = File(destination, entry.name)
                if (!output.canonicalPath.startsWith(root)) {
                    throw SecurityException("Rejected unsafe model archive entry.")
                }
                if (entry.isDirectory) {
                    output.mkdirs()
                } else {
                    output.parentFile?.mkdirs()
                    BufferedOutputStream(FileOutputStream(output)).use { stream ->
                        zip.copyTo(stream)
                    }
                }
                zip.closeEntry()
            }
        }
    }

    private fun findModelDirectory(root: File): File? {
        if (isValidModel(root)) return root
        return root.walkTopDown().firstOrNull { it.isDirectory && isValidModel(it) }
    }

    private fun isValidModel(directory: File): Boolean =
        File(directory, "am").isDirectory &&
            (File(directory, "conf").isDirectory || File(directory, "graph").isDirectory)

    private fun loadModel(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")?.let(::File)
        if (path == null || !isValidModel(path)) {
            result.error("MODEL_PATH_INVALID", "The extracted Vosk model directory is missing or incomplete.", null)
            return
        }
        worker.execute {
            try {
                stopRecognition()
                val loaded = Model(path.absolutePath)
                val previous = model
                model = loaded
                previous?.close()
                Log.i(TAG, "Loaded Vosk model from ${path.absolutePath}")
                postSuccess(result, true)
            } catch (error: Throwable) {
                Log.e(TAG, "Model load failed", error)
                postError(result, "MODEL_LOAD_FAILED", error.message ?: "Unable to load Vosk model.")
            }
        }
    }

    private fun start(result: MethodChannel.Result) {
        if (model == null) {
            result.error("MODEL_NOT_LOADED", "Download an offline language model first.", null)
            return
        }
        if (speechService != null) {
            result.success(true)
            return
        }
        worker.execute {
            try {
                val activeRecognizer = Recognizer(
                    model ?: throw IllegalStateException("Vosk model is no longer loaded."),
                    SAMPLE_RATE
                ).apply {
                    setWords(true)
                    setPartialWords(true)
                }
                val activeService = SpeechService(activeRecognizer, SAMPLE_RATE)
                recognizer = activeRecognizer
                speechService = activeService
                val started = activeService.startListening(object : RecognitionListener {
                    override fun onPartialResult(hypothesis: String) = emit("partial", hypothesis)
                    override fun onResult(hypothesis: String) = emit("result", hypothesis)
                    override fun onFinalResult(hypothesis: String) = emit("final", hypothesis)
                    override fun onError(exception: Exception) {
                        Log.e(TAG, "Recognition error", exception)
                        emit("error", exception.message ?: "Speech recognition failed.")
                    }
                    override fun onTimeout() = emit("timeout", "")
                })
                if (!started) throw IllegalStateException("Vosk could not start microphone capture.")
                Log.i(TAG, "Vosk microphone stream started at 16 kHz mono PCM")
                postSuccess(result, true)
            } catch (error: Throwable) {
                Log.e(TAG, "Could not start Vosk", error)
                stopRecognition()
                postError(result, "RECOGNITION_START_FAILED", error.message ?: "Could not start Vosk.")
            }
        }
    }

    private fun stop(result: MethodChannel.Result) {
        worker.execute {
            try {
                stopRecognition()
                postSuccess(result, true)
            } catch (error: Throwable) {
                postError(result, "RECOGNITION_STOP_FAILED", error.message ?: "Could not stop Vosk.")
            }
        }
    }

    private fun stopRecognition() {
        val service = speechService
        speechService = null
        try {
            service?.stop()
        } finally {
            try { service?.shutdown() } catch (error: Throwable) {
                Log.w(TAG, "AudioRecord shutdown warning", error)
            }
            val activeRecognizer = recognizer
            recognizer = null
            try { activeRecognizer?.close() } catch (error: Throwable) {
                Log.w(TAG, "Recognizer close warning", error)
            }
        }
    }

    private fun emit(type: String, payload: Any) {
        main.post { eventSink?.success(mapOf("type" to type, "payload" to payload)) }
    }

    private fun postSuccess(result: MethodChannel.Result, value: Any) {
        main.post { result.success(value) }
    }

    private fun postError(result: MethodChannel.Result, code: String, message: String) {
        main.post { result.error(code, message, null) }
    }
}
