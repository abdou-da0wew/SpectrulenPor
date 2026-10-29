package com.spectraglass.app

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.FloatBuffer
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * YOLO26-Nano ONNX Runtime inference channel.
 *
 * Provisioning strategy (bundled + first-startup extraction + auto-download fallback):
 *   1. Checks `<filesDir>/models/yolo26n.onnx` for a verified local copy.
 *   2. On first startup after install (or app update), extracts the bundled
 *      Flutter asset (`assets/models/yolo26n.onnx`, 5.04 MB) atomically to
 *      `<filesDir>/models/yolo26n.onnx`.
 *   3. If the APK was built without the bundled asset or the local file is
 *      missing/corrupt, automatically downloads `yolo26n.onnx` over HTTPS from
 *      the official Ultralytics release mirror into `<filesDir>/models/yolo26n.onnx`.
 *   4. Opens `OrtSession` directly from the file path so ONNX Runtime can
 *      memory-map weights instead of duplicating 5 MB byte arrays on the JVM heap.
 *
 * Verified against bundled `assets/models/yolo26n.onnx` (Ultralytics v8.4.0,
 * opset 22, `end2end=True`):
 *   - Input : `images`  FLOAT32 [1, 3, 640, 640] (RGB normalized 0..1, letterboxed)
 *   - Output: `output0` FLOAT32 [1, 300, 6]      ([x1, y1, x2, y2, score, class_id] in 0..640 px)
 *   - Also supports classic YOLO `[1, 84, 8400]` and `[1, 8400, 84]` heads.
 */
object YoloInferenceChannel {
    private const val TAG = "YoloChannel"
    private const val CHANNEL = "com.spectraglass/yolo"
    private const val INPUT_SIZE = 640
    private const val DEFAULT_CONF_THRESHOLD = 0.25f
    private const val IOU_THRESHOLD = 0.45f
    private const val MIN_VALID_MODEL_BYTES = 1_000_000L

    private val DEFAULT_DOWNLOAD_URLS = listOf(
        "https://github.com/ultralytics/assets/releases/download/v8.4.0/yolo26n.onnx",
        "https://github.com/ultralytics/assets/releases/download/v8.3.0/yolo11n.onnx"
    )

    private var ortEnv: OrtEnvironment? = null
    @Volatile private var ortSession: OrtSession? = null
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile private var modelSource: String = "uninitialized"
    @Volatile private var modelPath: String = ""
    @Volatile private var modelSizeBytes: Long = 0L
    @Volatile private var isEnd2End: Boolean = true
    @Volatile private var lastInferenceMs: Long = 0L
    @Volatile private var inputShapeStr: String = "[1, 3, 640, 640]"
    @Volatile private var outputShapeStr: String = "[1, 300, 6]"
    @Volatile private var dynamicLabels: List<String> = emptyList()

    /** Standard 80 COCO class names matching Ultralytics YOLO26n metadata. */
    private val COCO_LABELS = listOf(
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
        "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
        "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
        "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
        "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
        "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
        "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
        "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse",
        "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator",
        "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush"
    )

    private fun activeLabels(): List<String> =
        if (dynamicLabels.isNotEmpty()) dynamicLabels else COCO_LABELS

    fun register(flutterEngine: FlutterEngine, context: Context) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handle(call, result, context) }
    }

    private fun postSuccess(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun postError(result: MethodChannel.Result, code: String, message: String?) {
        mainHandler.post { result.error(code, message, null) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result, context: Context) {
        when (call.method) {
            "init", "ensureModel" -> {
                val forceDownload = call.argument<Boolean>("forceDownload") ?: false
                val customUrl = call.argument<String>("downloadUrl")
                executor.execute {
                    try {
                        initModel(context, forceDownload = forceDownload, customUrl = customUrl)
                        if (call.method == "ensureModel") {
                            postSuccess(result, buildStatusMap())
                        } else {
                            postSuccess(result, true)
                        }
                    } catch (t: Throwable) {
                        Log.e(TAG, "init/ensureModel failed", t)
                        postError(result, "INIT_FAILED", t.message)
                    }
                }
            }
            "detect" -> {
                val bytes = call.argument<ByteArray>("jpgBytes")
                val confThreshold =
                    (call.argument<Double>("confThreshold")?.toFloat()) ?: DEFAULT_CONF_THRESHOLD
                if (bytes == null || bytes.isEmpty()) {
                    result.error("BAD_ARGS", "jpgBytes required", null)
                    return
                }
                executor.execute {
                    try {
                        if (ortSession == null) initModel(context)
                        val t0 = System.nanoTime()
                        val boxes = detectOnFrame(bytes, confThreshold)
                        lastInferenceMs = (System.nanoTime() - t0) / 1_000_000L
                        postSuccess(result, boxes)
                    } catch (t: Throwable) {
                        Log.e(TAG, "detect failed", t)
                        postError(result, "DETECT_FAILED", t.message)
                    }
                }
            }
            "labels" -> result.success(activeLabels())
            "status" -> result.success(buildStatusMap())
            else -> result.notImplemented()
        }
    }

    private fun buildStatusMap(): Map<String, Any> = mapOf(
        "ready" to (ortSession != null),
        "modelSource" to modelSource,
        "modelPath" to modelPath,
        "modelSizeBytes" to modelSizeBytes,
        "end2end" to isEnd2End,
        "lastInferenceMs" to lastInferenceMs,
        "inputShape" to inputShapeStr,
        "outputShape" to outputShapeStr,
        "labelCount" to activeLabels().size
    )

    @Synchronized
    private fun initModel(
        context: Context,
        forceDownload: Boolean = false,
        customUrl: String? = null
    ) {
        if (ortSession != null && !forceDownload) return

        val modelFile = provisionModelFile(context, forceDownload, customUrl)
        modelPath = modelFile.absolutePath
        modelSizeBytes = modelFile.length()

        val env = ortEnv ?: OrtEnvironment.getEnvironment().also { ortEnv = it }
        val opts = OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(2)
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
        }

        ortSession?.close()
        val session = env.createSession(modelFile.absolutePath, opts)
        ortSession = session

        // Inspect embedded ONNX metadata & shapes.
        try {
            val meta = session.metadata.customMetadata
            meta["end2end"]?.let { isEnd2End = it.equals("true", ignoreCase = true) }
            meta["names"]?.let { namesStr ->
                val parsed = parsePythonDictLabels(namesStr)
                if (parsed.isNotEmpty()) {
                    dynamicLabels = parsed
                }
            }
            session.inputInfo.values.firstOrNull()?.info?.let { inputShapeStr = it.toString() }
            session.outputInfo.values.firstOrNull()?.info?.let { outputShapeStr = it.toString() }
        } catch (t: Throwable) {
            Log.w(TAG, "Metadata inspection warning: ${t.message}")
        }

        Log.i(
            TAG,
            "YOLO26-Nano ready ($modelSource): ${modelSizeBytes / 1024} KB, " +
                "end2end=$isEnd2End, labels=${activeLabels().size}, out=$outputShapeStr"
        )
    }

    /**
     * Ensures `<filesDir>/models/yolo26n.onnx` exists and is valid:
     *   1. Reuse existing verified file on internal storage (unless `forceDownload`).
     *   2. Extract bundled APK asset (`assets/models/yolo26n.onnx`) on first startup.
     *   3. Auto-download over HTTPS if asset is unavailable or `forceDownload` is true.
     */
    private fun provisionModelFile(
        context: Context,
        forceDownload: Boolean,
        customUrl: String?
    ): File {
        val dir = File(context.filesDir, "models")
        if (!dir.exists()) dir.mkdirs()
        val target = File(dir, "yolo26n.onnx")

        if (!forceDownload && target.exists() && target.length() >= MIN_VALID_MODEL_BYTES) {
            modelSource = "cached_local"
            return target
        }

        if (!forceDownload && extractBundledAsset(context, target)) {
            modelSource = "bundled_asset"
            return target
        }

        val urls = buildList {
            if (!customUrl.isNullOrBlank()) add(customUrl.trim())
            addAll(DEFAULT_DOWNLOAD_URLS)
        }
        var lastErr: Throwable? = null
        for (u in urls) {
            try {
                downloadModelToFile(u, target)
                if (target.exists() && target.length() >= MIN_VALID_MODEL_BYTES) {
                    modelSource = "auto_downloaded"
                    return target
                }
            } catch (t: Throwable) {
                lastErr = t
                Log.w(TAG, "Auto-download attempt failed ($u): ${t.message}")
            }
        }

        // Last resort if forceDownload failed offline but cached/bundled exists
        if (target.exists() && target.length() >= MIN_VALID_MODEL_BYTES) {
            modelSource = "cached_local"
            return target
        }
        if (extractBundledAsset(context, target)) {
            modelSource = "bundled_asset"
            return target
        }
        throw IllegalStateException(
            "Unable to provision yolo26n.onnx from bundled assets or download (${lastErr?.message})"
        )
    }

    private fun extractBundledAsset(context: Context, target: File): Boolean {
        val loader = FlutterInjector.instance().flutterLoader()
        val candidates = listOf(
            loader.getLookupKeyForAsset("assets/models/yolo26n.onnx"),
            "flutter_assets/assets/models/yolo26n.onnx",
            "models/yolo26n.onnx",
            "yolo26n.onnx"
        ).distinct()

        for (candidate in candidates) {
            try {
                val tmp = File(target.parentFile, "${target.name}.tmp")
                context.assets.open(candidate).use { input ->
                    FileOutputStream(tmp).use { output ->
                        input.copyTo(output, bufferSize = 64 * 1024)
                        output.fd.sync()
                    }
                }
                if (tmp.length() >= MIN_VALID_MODEL_BYTES) {
                    if (target.exists()) target.delete()
                    if (tmp.renameTo(target)) {
                        Log.i(TAG, "Extracted bundled asset '$candidate' -> ${target.absolutePath}")
                        return true
                    }
                } else {
                    tmp.delete()
                }
            } catch (_: Throwable) {
                // Try next candidate path.
            }
        }
        return false
    }

    private fun downloadModelToFile(urlStr: String, target: File) {
        val tmp = File(target.parentFile, "${target.name}.dl.tmp")
        var conn: HttpURLConnection? = null
        try {
            conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                connectTimeout = 15_000
                readTimeout = 45_000
                instanceFollowRedirects = true
                setRequestProperty("User-Agent", "SpectruLenPor/5.4")
            }
            val code = conn.responseCode
            if (code !in 200..299) {
                throw IllegalStateException("HTTP $code from $urlStr")
            }
            conn.inputStream.use { input ->
                FileOutputStream(tmp).use { output ->
                    input.copyTo(output, bufferSize = 64 * 1024)
                    output.fd.sync()
                }
            }
            if (tmp.length() < MIN_VALID_MODEL_BYTES) {
                tmp.delete()
                throw IllegalStateException("Downloaded file too small (${tmp.length()} bytes)")
            }
            if (target.exists()) target.delete()
            if (!tmp.renameTo(target)) {
                throw IllegalStateException("Failed to move downloaded model into place")
            }
            Log.i(TAG, "Auto-downloaded YOLO26-Nano model from $urlStr (${target.length()} bytes)")
        } finally {
            conn?.disconnect()
            if (tmp.exists()) tmp.delete()
        }
    }

    /** Parses Ultralytics metadata string `{0: 'person', 1: 'bicycle', ...}`. */
    private fun parsePythonDictLabels(raw: String): List<String> {
        val regex = Regex("""(\d+)\s*:\s*['"]([^'"]+)['"]""")
        val map = sortedMapOf<Int, String>()
        for (m in regex.findAll(raw)) {
            val idx = m.groupValues[1].toIntOrNull() ?: continue
            map[idx] = m.groupValues[2]
        }
        if (map.isEmpty()) return emptyList()
        val maxIdx = map.keys.maxOrNull() ?: return emptyList()
        return (0..maxIdx).map { map[it] ?: "class_$it" }
    }

    /**
     * Reads JPEG EXIF orientation tag (0x0112) without external AndroidX ExifInterface dep
     * so sideways camera JPEGs with EXIF orientation metadata are rotated upright.
     */
    private fun decodeUprightBitmap(jpegBytes: ByteArray): Bitmap? {
        val raw = BitmapFactory.decodeByteArray(jpegBytes, 0, jpegBytes.size) ?: return null
        val degrees = readJpegExifRotationDegrees(jpegBytes)
        if (degrees == 0) return raw
        val matrix = Matrix().apply { postRotate(degrees.toFloat()) }
        val rotated = Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, matrix, true)
        if (rotated !== raw) raw.recycle()
        return rotated
    }

    private fun readJpegExifRotationDegrees(jpeg: ByteArray): Int {
        try {
            if (jpeg.size < 14 || jpeg[0] != 0xFF.toByte() || jpeg[1] != 0xD8.toByte()) return 0
            var offset = 2
            while (offset + 4 < jpeg.size && jpeg[offset] == 0xFF.toByte()) {
                val marker = jpeg[offset + 1].toInt() and 0xFF
                if (marker == 0xDA || marker == 0xD9) break
                val segLen = ((jpeg[offset + 2].toInt() and 0xFF) shl 8) or
                    (jpeg[offset + 3].toInt() and 0xFF)
                if (segLen < 2 || offset + 2 + segLen > jpeg.size) break
                if (marker == 0xE1 && segLen >= 14) {
                    val hdr = offset + 4
                    if (jpeg[hdr] == 'E'.code.toByte() &&
                        jpeg[hdr + 1] == 'x'.code.toByte() &&
                        jpeg[hdr + 2] == 'i'.code.toByte() &&
                        jpeg[hdr + 3] == 'f'.code.toByte()
                    ) {
                        val tiff = hdr + 6
                        val little = jpeg[tiff] == 'I'.code.toByte()
                        fun u16(p: Int): Int = if (little) {
                            (jpeg[p].toInt() and 0xFF) or ((jpeg[p + 1].toInt() and 0xFF) shl 8)
                        } else {
                            ((jpeg[p].toInt() and 0xFF) shl 8) or (jpeg[p + 1].toInt() and 0xFF)
                        }
                        fun u32(p: Int): Int = if (little) {
                            u16(p) or (u16(p + 2) shl 16)
                        } else {
                            (u16(p) shl 16) or u16(p + 2)
                        }
                        val ifd0 = tiff + u32(tiff + 4)
                        if (ifd0 + 2 <= jpeg.size) {
                            val entries = u16(ifd0)
                            for (i in 0 until entries) {
                                val ep = ifd0 + 2 + i * 12
                                if (ep + 12 > jpeg.size) break
                                if (u16(ep) == 0x0112) {
                                    return when (u16(ep + 8)) {
                                        3 -> 180
                                        6 -> 90
                                        8 -> 270
                                        else -> 0
                                    }
                                }
                            }
                        }
                    }
                }
                offset += 2 + segLen
            }
        } catch (_: Throwable) {}
        return 0
    }

    /** Run YOLO26-Nano on a single JPEG frame; returns normalized [0..1] boxes. */
    private fun detectOnFrame(jpegBytes: ByteArray, confThreshold: Float): List<Map<String, Any>> {
        val session = ortSession ?: throw IllegalStateException("Session not initialized")
        val env = ortEnv ?: throw IllegalStateException("Env not initialized")
        val labels = activeLabels()

        // 1. Decode JPEG (honoring EXIF orientation if present)
        val orig = decodeUprightBitmap(jpegBytes) ?: return emptyList()
        val origW = orig.width
        val origH = orig.height
        if (origW <= 0 || origH <= 0) {
            orig.recycle()
            return emptyList()
        }

        // 2. Letterbox resize to 640x640 (aspect ratio preserved, gray 114 padding)
        val scale = min(INPUT_SIZE.toFloat() / origW, INPUT_SIZE.toFloat() / origH)
        val newW = (origW * scale).roundToInt().coerceAtLeast(1)
        val newH = (origH * scale).roundToInt().coerceAtLeast(1)
        val padX = (INPUT_SIZE - newW) / 2f
        val padY = (INPUT_SIZE - newH) / 2f

        val resized = Bitmap.createScaledBitmap(orig, newW, newH, true)
        if (resized !== orig) orig.recycle()

        val letterboxed = Bitmap.createBitmap(INPUT_SIZE, INPUT_SIZE, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(letterboxed)
        canvas.drawColor(Color.rgb(114, 114, 114))
        canvas.drawBitmap(resized, padX, padY, Paint(Paint.FILTER_BITMAP_FLAG))
        resized.recycle()

        // 3. Bulk pixel extraction -> NCHW float32 RGB normalized [0..1]
        val planeSize = INPUT_SIZE * INPUT_SIZE
        val pixels = IntArray(planeSize)
        letterboxed.getPixels(pixels, 0, INPUT_SIZE, 0, 0, INPUT_SIZE, INPUT_SIZE)
        letterboxed.recycle()

        val floatData = FloatArray(3 * planeSize)
        val inv255 = 1.0f / 255.0f
        for (idx in 0 until planeSize) {
            val px = pixels[idx]
            floatData[idx] = ((px shr 16) and 0xFF) * inv255
            floatData[planeSize + idx] = ((px shr 8) and 0xFF) * inv255
            floatData[2 * planeSize + idx] = (px and 0xFF) * inv255
        }

        val inputName = session.inputNames.iterator().next()
        val shape = longArrayOf(1, 3, INPUT_SIZE.toLong(), INPUT_SIZE.toLong())
        val raw = ArrayList<Detection>()

        OnnxTensor.createTensor(env, FloatBuffer.wrap(floatData), shape).use { inputTensor ->
            session.run(mapOf(inputName to inputTensor)).use { output ->
                val outValue = output[0].value
                @Suppress("UNCHECKED_CAST")
                val batch = (outValue as Array<Array<FloatArray>>)[0]
                if (batch.isEmpty() || batch[0].isEmpty()) return emptyList()

                if (batch[0].size == 6) {
                    // YOLO26n end-to-end head: [300, 6] -> [x1, y1, x2, y2, score, class_id]
                    // Check max coordinate across valid rows: Ultralytics end2end outputs 0..640 px.
                    var maxCoord = 0f
                    for (row in batch) {
                        if (row[4] >= confThreshold) {
                            maxCoord = max(maxCoord, max(row[2], row[3]))
                        }
                    }
                    val normalizedCoords = maxCoord in 0.0001f..1.05f
                    val coordScale = if (normalizedCoords) INPUT_SIZE.toFloat() else 1f

                    for (row in batch) {
                        val score = row[4]
                        if (score < confThreshold) continue
                        val clsIdx = row[5].roundToInt()
                        if (clsIdx !in labels.indices) continue
                        val x1 = row[0] * coordScale
                        val y1 = row[1] * coordScale
                        val x2 = row[2] * coordScale
                        val y2 = row[3] * coordScale
                        addUnletterboxed(
                            raw, x1, y1, x2, y2, padX, padY, scale, origW, origH, clsIdx, score
                        )
                    }
                } else {
                    // Classic YOLO head: [84, 8400] or [8400, 84] -> [cx, cy, w, h, cls0..cls79]
                    val nPreds: Int
                    val nFields: Int
                    val transposed: Boolean
                    if (batch.size == labels.size + 4 && batch[0].size > batch.size) {
                        nFields = batch.size
                        nPreds = batch[0].size
                        transposed = false
                    } else {
                        nPreds = batch.size
                        nFields = batch[0].size
                        transposed = true
                    }
                    val numClasses = min(labels.size, nFields - 4)
                    if (numClasses <= 0) return emptyList()

                    for (i in 0 until nPreds) {
                        val cx = if (transposed) batch[i][0] else batch[0][i]
                        val cy = if (transposed) batch[i][1] else batch[1][i]
                        val w = if (transposed) batch[i][2] else batch[2][i]
                        val h = if (transposed) batch[i][3] else batch[3][i]
                        var bestClass = 0
                        var bestScore = 0f
                        for (c in 0 until numClasses) {
                            val s = if (transposed) batch[i][4 + c] else batch[4 + c][i]
                            if (s > bestScore) {
                                bestScore = s
                                bestClass = c
                            }
                        }
                        if (bestScore >= confThreshold) {
                            addUnletterboxed(
                                raw,
                                cx - w / 2f,
                                cy - h / 2f,
                                cx + w / 2f,
                                cy + h / 2f,
                                padX,
                                padY,
                                scale,
                                origW,
                                origH,
                                bestClass,
                                bestScore
                            )
                        }
                    }
                }
            }
        }

        // 4. Class-aware NMS safety net (handles both classic heads and duplicate overlaps)
        val kept = nms(raw, IOU_THRESHOLD)
        return kept.map { d ->
            mapOf(
                "x" to d.x.toDouble(),
                "y" to d.y.toDouble(),
                "w" to d.w.toDouble(),
                "h" to d.h.toDouble(),
                "label" to labels[d.classIdx],
                "classIndex" to d.classIdx,
                "confidence" to d.score.toDouble()
            )
        }
    }

    private fun addUnletterboxed(
        out: MutableList<Detection>,
        x1Letterbox: Float,
        y1Letterbox: Float,
        x2Letterbox: Float,
        y2Letterbox: Float,
        padX: Float,
        padY: Float,
        scale: Float,
        origW: Int,
        origH: Int,
        classIdx: Int,
        score: Float
    ) {
        val x1 = ((x1Letterbox - padX) / scale / origW).coerceIn(0f, 1f)
        val y1 = ((y1Letterbox - padY) / scale / origH).coerceIn(0f, 1f)
        val x2 = ((x2Letterbox - padX) / scale / origW).coerceIn(0f, 1f)
        val y2 = ((y2Letterbox - padY) / scale / origH).coerceIn(0f, 1f)
        val nw = (x2 - x1).coerceAtLeast(0f)
        val nh = (y2 - y1).coerceAtLeast(0f)
        if (nw >= 0.01f && nh >= 0.01f) {
            out.add(Detection(x1, y1, nw, nh, classIdx, score))
        }
    }

    private data class Detection(
        val x: Float,
        val y: Float,
        val w: Float,
        val h: Float,
        val classIdx: Int,
        val score: Float
    )

    private fun nms(boxes: List<Detection>, iouThresh: Float): List<Detection> {
        val sorted = boxes.sortedByDescending { it.score }
        val kept = ArrayList<Detection>()
        val suppressed = BooleanArray(sorted.size)
        for (i in sorted.indices) {
            if (suppressed[i]) continue
            val a = sorted[i]
            kept.add(a)
            for (j in (i + 1) until sorted.size) {
                if (suppressed[j]) continue
                val b = sorted[j]
                if (a.classIdx == b.classIdx && iou(a, b) > iouThresh) {
                    suppressed[j] = true
                }
            }
        }
        return kept
    }

    private fun iou(a: Detection, b: Detection): Float {
        val ax2 = a.x + a.w
        val ay2 = a.y + a.h
        val bx2 = b.x + b.w
        val by2 = b.y + b.h
        val ix1 = max(a.x, b.x)
        val iy1 = max(a.y, b.y)
        val ix2 = min(ax2, bx2)
        val iy2 = min(ay2, by2)
        val iw = max(0f, ix2 - ix1)
        val ih = max(0f, iy2 - iy1)
        val inter = iw * ih
        val union = a.w * a.h + b.w * b.h - inter
        return if (union <= 0f) 0f else inter / union
    }
}
