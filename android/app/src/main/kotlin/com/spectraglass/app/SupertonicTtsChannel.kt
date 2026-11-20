package com.spectraglass.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.FloatBuffer
import java.nio.LongBuffer
import java.util.Random
import java.util.concurrent.Executors
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.PI
import kotlin.math.sqrt

/** CPU ONNX implementation of Supertonic-3. Models are downloaded by Dart on demand. */
object SupertonicTtsChannel {
    private const val TAG = "SupertonicTTS"
    private const val CHANNEL = "spectrulenpor/supertonic"
    private const val MAX_CHUNK_CHARS = 240
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var environment: OrtEnvironment? = null
    private var durationSession: OrtSession? = null
    private var textSession: OrtSession? = null
    private var vectorSession: OrtSession? = null
    private var vocoderSession: OrtSession? = null
    private var loadedDirectory: String? = null
    private var unicodeIndexer: Map<Int, Int>? = null

    fun register(engine: FlutterEngine, context: Context) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "synthesize" -> synthesize(call, context.applicationContext, result)
                    "release" -> worker.execute {
                        closeSessions()
                        main.post { result.success(true) }
                    }
                    "status" -> result.success(mapOf("loaded" to (loadedDirectory != null)))
                    else -> result.notImplemented()
                }
            }
    }

    private fun synthesize(call: io.flutter.plugin.common.MethodCall, context: Context, result: MethodChannel.Result) {
        val text = call.argument<String>("text")?.trim().orEmpty()
        val language = call.argument<String>("language") ?: "en"
        val directory = call.argument<String>("modelDirectory")?.let(::File)
        val styleFile = call.argument<String>("styleFile")?.let(::File)
        val steps = (call.argument<Int>("steps") ?: 4).coerceIn(2, 8)
        val speed = (call.argument<Double>("speed") ?: 1.0).toFloat().coerceIn(0.75f, 1.3f)
        if (text.isBlank() || language !in setOf("ar", "en") ||
            directory == null || styleFile == null || !styleFile.isFile
        ) {
            result.error("INVALID_ARGUMENTS", "Text, Arabic or English, and downloaded model files are required.", null)
            return
        }
        worker.execute {
            try {
                ensureSessions(directory)
                val wav = synthesizeText(text, language, directory, styleFile, steps, speed)
                val output = File(context.cacheDir, "supertonic_${System.currentTimeMillis()}.wav")
                writeWav(output, wav, readSampleRate(File(directory, "tts.json")))
                main.post {
                    result.success(mapOf(
                        "path" to output.absolutePath,
                        "sampleRate" to readSampleRate(File(directory, "tts.json")),
                        "durationMs" to (wav.size * 1000L / readSampleRate(File(directory, "tts.json")))
                    ))
                }
            } catch (error: Throwable) {
                Log.e(TAG, "Local synthesis failed", error)
                main.post { result.error("SYNTHESIS_FAILED", error.message ?: "Supertonic synthesis failed.", null) }
            }
        }
    }

    private fun ensureSessions(directory: File) {
        val names = listOf("duration_predictor.onnx", "text_encoder.onnx", "vector_estimator.onnx", "vocoder.onnx")
        names.forEach { name ->
            val file = File(directory, name)
            require(file.isFile && file.length() > 100_000L) { "Missing or incomplete Supertonic file: $name" }
        }
        if (loadedDirectory == directory.absolutePath && durationSession != null) return
        closeSessions()
        val env = environment ?: OrtEnvironment.getEnvironment().also { environment = it }
        val options = OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(2)
            setInterOpNumThreads(1)
            setExecutionMode(OrtSession.SessionOptions.ExecutionMode.SEQUENTIAL)
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
        }
        try {
            durationSession = env.createSession(File(directory, names[0]).absolutePath, options)
            textSession = env.createSession(File(directory, names[1]).absolutePath, options)
            vectorSession = env.createSession(File(directory, names[2]).absolutePath, options)
            vocoderSession = env.createSession(File(directory, names[3]).absolutePath, options)
            loadedDirectory = directory.absolutePath
        } finally {
            options.close()
        }
    }

    private fun closeSessions() {
        listOf(durationSession, textSession, vectorSession, vocoderSession).forEach {
            try { it?.close() } catch (_: Exception) { }
        }
        durationSession = null
        textSession = null
        vectorSession = null
        vocoderSession = null
        loadedDirectory = null
        unicodeIndexer = null
    }

    private fun synthesizeText(
        text: String,
        language: String,
        directory: File,
        styleFile: File,
        steps: Int,
        speed: Float
    ): FloatArray {
        val config = JSONObject(File(directory, "tts.json").readText())
        val sampleRate = config.getJSONObject("ae").getInt("sample_rate")
        val baseChunk = config.getJSONObject("ae").getInt("base_chunk_size")
        val ttl = config.getJSONObject("ttl")
        val compress = ttl.getInt("chunk_compress_factor")
        val latentDimension = ttl.getInt("latent_dim") * compress
        val style = JSONObject(styleFile.readText())
        val ttlStyle = styleTensor(style.getJSONObject("style_ttl"))
        val dpStyle = styleTensor(style.getJSONObject("style_dp"))
        val chunks = SupertonicTextProcessor.splitText(text, MAX_CHUNK_CHARS)
        val outputs = ArrayList<FloatArray>()
        chunks.forEachIndexed { index, chunk ->
            val speech = inferChunk(
                chunk, language, sampleRate, baseChunk * compress,
                latentDimension, steps, speed, ttlStyle, dpStyle
            )
            if (index > 0) outputs.add(FloatArray((sampleRate * 0.16f).toInt()))
            outputs.add(speech)
        }
        return outputs.fold(FloatArray(0)) { acc, next -> acc + next }
    }

    private fun inferChunk(
        text: String, language: String, sampleRate: Int, chunkSize: Int,
        latentDimension: Int, steps: Int, speed: Float,
        ttlStyle: TensorData, dpStyle: TensorData
    ): FloatArray {
        val env = environment ?: error("ONNX runtime is not initialized.")
        val durationModel = durationSession ?: error("Duration model is not loaded.")
        val textModel = textSession ?: error("Text encoder is not loaded.")
        val vectorModel = vectorSession ?: error("Vector estimator is not loaded.")
        val vocoderModel = vocoderSession ?: error("Vocoder is not loaded.")
        val normalized = SupertonicTextProcessor.preprocessText(text)
        val indexer = unicodeIndexer ?: SupertonicTextProcessor
            .readUnicodeIndexer(File(loadedDirectory ?: error("Model directory is not loaded."), "unicode_indexer.json"))
            .also { unicodeIndexer = it }
        val tagged = "<$language>$normalized</$language>"
        val codepoints = tagged.codePoints().toArray()
        val ids = LongArray(codepoints.size) { indexer[codepoints[it]]?.toLong() ?: 0L }
        val mask = FloatArray(codepoints.size) { 1f }
        val durationData = runTensor(durationModel, mapOf(
            "text_ids" to longTensor(env, ids, longArrayOf(1, ids.size.toLong())),
            "style_dp" to floatTensor(env, dpStyle.values, dpStyle.shape),
            "text_mask" to floatTensor(env, mask, longArrayOf(1, 1, mask.size.toLong()))
        ))
        val duration = durationData.values.firstOrNull()?.div(speed)?.coerceIn(0.25f, 20f)
            ?: error("Duration predictor returned no duration.")
        val textEmbedding = runTensor(textModel, mapOf(
            "text_ids" to longTensor(env, ids, longArrayOf(1, ids.size.toLong())),
            "style_ttl" to floatTensor(env, ttlStyle.values, ttlStyle.shape),
            "text_mask" to floatTensor(env, mask, longArrayOf(1, 1, mask.size.toLong()))
        ))
        val latentLength = ceil(duration * sampleRate / chunkSize).toInt().coerceIn(1, 180)
        val latentSize = latentDimension * latentLength
        val random = Random()
        val latent = FloatArray(latentSize) { gaussian(random) }
        val latentMask = FloatArray(latentLength) { 1f }
        for (channel in 0 until latentDimension) {
            for (time in 0 until latentLength) {
                if (time * chunkSize >= duration * sampleRate) latent[channel * latentLength + time] = 0f
            }
        }
        repeat(steps) { step ->
            val inputs = linkedMapOf(
                "noisy_latent" to floatTensor(env, latent, longArrayOf(1, latentDimension.toLong(), latentLength.toLong())),
                "text_emb" to floatTensor(env, textEmbedding.values, textEmbedding.shape),
                "style_ttl" to floatTensor(env, ttlStyle.values, ttlStyle.shape),
                "text_mask" to floatTensor(env, mask, longArrayOf(1, 1, mask.size.toLong())),
                "latent_mask" to floatTensor(env, latentMask, longArrayOf(1, 1, latentLength.toLong())),
                "total_step" to floatTensor(env, floatArrayOf(steps.toFloat()), longArrayOf(1)),
                "current_step" to floatTensor(env, floatArrayOf(step.toFloat()), longArrayOf(1))
            )
            val update = runTensor(vectorModel, inputs).values
            if (update.size != latent.size) error("Vector estimator output shape mismatch.")
            for (i in latent.indices) latent[i] = update[i]
        }
        return runTensor(vocoderModel, mapOf(
            "latent" to floatTensor(env, latent, longArrayOf(1, latentDimension.toLong(), latentLength.toLong()))
        )).values
    }

    private fun runTensor(session: OrtSession, inputs: Map<String, OnnxTensor>): TensorData {
        return try {
            session.run(inputs).use { output ->
                val tensor = output[0] as OnnxTensor
                val buffer = tensor.floatBuffer
                val values = FloatArray(buffer.remaining()).also { buffer.get(it) }
                val shape = (tensor.info as ai.onnxruntime.TensorInfo).shape
                TensorData(values, shape)
            }
        } finally {
            inputs.values.forEach { try { it.close() } catch (_: Exception) { } }
        }
    }

    private fun floatTensor(env: OrtEnvironment, values: FloatArray, shape: LongArray): OnnxTensor =
        OnnxTensor.createTensor(env, FloatBuffer.wrap(values), shape)

    private fun longTensor(env: OrtEnvironment, values: LongArray, shape: LongArray): OnnxTensor =
        OnnxTensor.createTensor(env, LongBuffer.wrap(values), shape)

    private data class TensorData(val values: FloatArray, val shape: LongArray)

    private fun styleTensor(json: JSONObject): TensorData {
        val dims = json.getJSONArray("dims")
        val shape = LongArray(dims.length()) { dims.getInt(it).toLong() }
        return TensorData(flatten(json.getJSONArray("data")), shape)
    }

    private fun flatten(value: JSONArray): FloatArray {
        val output = ArrayList<Float>()
        fun walk(item: Any?) {
            when (item) {
                is JSONArray -> for (i in 0 until item.length()) walk(item.get(i))
                is Number -> output.add(item.toFloat())
            }
        }
        walk(value)
        return output.toFloatArray()
    }

    private fun gaussian(random: Random): Float {
        val a = max(1e-10, random.nextDouble())
        val b = random.nextDouble()
        return (sqrt(-2.0 * ln(a)) * cos(2.0 * PI * b)).toFloat()
    }

    private fun readSampleRate(config: File): Int =
        JSONObject(config.readText()).getJSONObject("ae").getInt("sample_rate")

    private fun writeWav(file: File, audio: FloatArray, sampleRate: Int) {
        val dataLength = audio.size * 2
        FileOutputStream(file).use { out ->
            fun writeInt(value: Int) {
                out.write(value and 0xff)
                out.write((value shr 8) and 0xff)
                out.write((value shr 16) and 0xff)
                out.write((value shr 24) and 0xff)
            }
            fun writeShort(value: Int) {
                out.write(value and 0xff)
                out.write((value shr 8) and 0xff)
            }
            out.write("RIFF".toByteArray(Charsets.US_ASCII))
            writeInt(36 + dataLength)
            out.write("WAVEfmt ".toByteArray(Charsets.US_ASCII))
            writeInt(16)
            writeShort(1)
            writeShort(1)
            writeInt(sampleRate)
            writeInt(sampleRate * 2)
            writeShort(2)
            writeShort(16)
            out.write("data".toByteArray(Charsets.US_ASCII))
            writeInt(dataLength)
            audio.forEach { sample ->
                val pcm = (sample.coerceIn(-1f, 1f) * 32767f).toInt()
                writeShort(pcm)
            }
        }
    }
}
