package com.spectraglass.app

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Matrix
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.FloatBuffer
import java.util.concurrent.Executors

/**
 * SpectruLenPor — YOLO26-Nano on-device inference channel.
 *
 * Loads the bundled `assets/models/yolo26n.onnx` model via the ONNX Runtime
 * Java API (com.microsoft.onnxruntime:onnxruntime-android) and runs inference
 * on JPEG bytes sent from Dart. Returns a list of detected objects as a list
 * of maps: { "x", "y", "w", "h", "label", "confidence" } — all normalized to
 * the original image dimensions (0.0..1.0).
 *
 * Pipeline:
 *   1. Decode JPEG → Bitmap
 *   2. Resize + letterbox to 640×640 (preserve aspect ratio)
 *   3. Normalize to 0..1 NCHW float32 [1, 3, 640, 640]
 *   4. Run ONNX inference
 *   5. Parse output: [1, 84, 8400] YOLO26 format (4 box + 80 classes × 8400 anchors)
 *      OR [1, 8400, 84] depending on export
 *   6. Apply NMS (IoU 0.45, conf 0.30)
 *   7. Convert boxes back to original image coords (un-letterbox)
 *   8. Return JSON-serializable List<Map>
 *
 * The inference runs on a background executor — never blocks the platform thread.
 */
class YoloInferenceChannel private constructor() {

    companion object {
        const val CHANNEL = "com.spectraglass/yolo"

        private const val INPUT_SIZE = 640
        private const val CONF_THRESHOLD = 0.30
        private const val IOU_THRESHOLD = 0.45
        // Treat as Double for arithmetic simplicity.

        // COCO 80-class label table (YOLO26 default export).
        private val COCO_LABELS = listOf(
            "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck",
            "boat", "traffic light", "fire hydrant", "stop sign", "parking meter", "bench",
            "bird", "cat", "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra",
            "giraffe", "backpack", "umbrella", "handbag", "tie", "suitcase", "frisbee",
            "skis", "snowboard", "sports ball", "kite", "baseball bat", "baseball glove",
            "skateboard", "surfboard", "tennis racket", "bottle", "wine glass", "cup",
            "fork", "knife", "spoon", "bowl", "banana", "apple", "sandwich", "orange",
            "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch",
            "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse",
            "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink",
            "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier",
            "toothbrush"
        )

        @Volatile private var session: OrtSession? = null
        @Volatile private var env: OrtEnvironment? = null
        private val executor = Executors.newSingleThreadExecutor()

        fun register(engine: FlutterEngine, context: Context) {
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "init" -> {
                            executor.execute {
                                try {
                                    if (session == null) {
                                        env = OrtEnvironment.getEnvironment()
                                        val opts = OrtSession.SessionOptions().apply {
                                            setIntraOpNumThreads(4)
                                        }
                                        // Load the model from the asset manager.
                                        context.assets.open("assets/models/yolo26n.onnx").use { input ->
                                            val bytes = input.readBytes()
                                            session = env?.createSession(bytes, opts)
                                        }
                                    }
                                    result.success(true)
                                } catch (e: Exception) {
                                    result.error("yolo_init_failed", e.message, null)
                                }
                            }
                        }
                        "detect" -> {
                            val jpgBytes = call.argument<ByteArray>("jpgBytes")
                            if (jpgBytes == null) {
                                result.error("bad_args", "jpgBytes required", null)
                                return@setMethodCallHandler
                            }
                            executor.execute {
                                try {
                                    val boxes = detect(context, jpgBytes)
                                    result.success(boxes)
                                } catch (e: Exception) {
                                    result.error("yolo_detect_failed", e.message, null)
                                }
                            }
                        }
                        "is_ready" -> result.success(session != null)
                        "labels" -> result.success(COCO_LABELS)
                        else -> result.notImplemented()
                    }
                }
        }

        /// Run inference. Returns a List<Map<String, Any>> (serializes as JSON List<dynamic>
        /// of Map<String, dynamic> in Dart).
        private fun detect(context: Context, jpgBytes: ByteArray): List<Map<String, Any>> {
            val session = session ?: return emptyList()

            // 1. Decode JPEG.
            val bmpIn = BitmapFactory.decodeByteArray(jpgBytes, 0, jpgBytes.size)
                ?: return emptyList()
            val origW = bmpIn.width
            val origH = bmpIn.height

            // 2. Letterbox-resize to 640×640.
            val scale: Double = minOf(INPUT_SIZE.toDouble() / origW, INPUT_SIZE.toDouble() / origH)
            val newW = (origW * scale).toInt().coerceAtLeast(1)
            val newH = (origH * scale).toInt().coerceAtLeast(1)  // scale is Double now
            val scaled = Bitmap.createScaledBitmap(bmpIn, newW, newH, true)
            val letterboxed = Bitmap.createBitmap(INPUT_SIZE, INPUT_SIZE, Bitmap.Config.ARGB_8888)
            val canvas = android.graphics.Canvas(letterboxed)
            canvas.drawColor(Color.rgb(114, 118, 130)) // YOLO gray letterbox
            canvas.drawBitmap(scaled, 0f, 0f, null)

            // 3. Normalize to NCHW float32 [1, 3, 640, 640].
            val inputBuf = FloatBuffer.allocate(3 * INPUT_SIZE * INPUT_SIZE)
            // ML Kit / Android convention: walk pixels row by row.
            for (y in 0 until INPUT_SIZE) {
                for (x in 0 until INPUT_SIZE) {
                    val px = letterboxed.getPixel(x, y)
                    val r = Color.red(px) / 255.0f
                    val g = Color.green(px) / 255.0f
                    val b = Color.blue(px) / 255.0f
                    // NCHW: channel-first layout
                    inputBuf.put(y * INPUT_SIZE + x, r)
                    inputBuf.put(INPUT_SIZE * INPUT_SIZE + y * INPUT_SIZE + x, g)
                    inputBuf.put(2 * INPUT_SIZE * INPUT_SIZE + y * INPUT_SIZE + x, b)
                }
            }
            inputBuf.rewind()

            val shape = longArrayOf(1L, 3L, INPUT_SIZE.toLong(), INPUT_SIZE.toLong())
            val inputTensor = OnnxTensor.createTensor(env, inputBuf, shape)
            val inputs = mapOf("images" to inputTensor)

            // 4. Run inference.
            val output = session.run(inputs)
            inputTensor.close()

            // 5. Parse output — YOLO26 export is typically [1, 84, 8400]
            //    (84 = 4 box coords xywh + 80 class probs).
            val rawOut = output[0].value as? Array<*>
                ?: (output[0].value as? List<*>)?.toTypedArray()
            output.close()
            rawOut ?: return emptyList()

            // rawOut is Array<Array<FloatArray>>? We need to handle multiple shapes.
            // Strategy: flatten and detect 8400-anchor output.
            val detections = mutableListOf<Detection>()

            // Try shape [1, 84, 8400] (transposed YOLOv8/YOLO26 default).
            try {
                @Suppress("UNCHECKED_CAST")
                val data = rawOut as Array<Array<FloatArray>>  // [1][84][8400]
                val inner = data[0]  // [84][8400]
                val numChannels = inner.size  // 84
                val numAnchors = inner[0].size  // 8400
                for (a in 0 until numAnchors) {
                    val cx = inner[0][a].toDouble()
                    val cy = inner[1][a].toDouble()
                    val w = inner[2][a].toDouble()
                    val h = inner[3][a].toDouble()
                    // Find best class
                    var maxConf: Double = 0.0
                    var maxIdx = 0
                    for (c in 4 until numChannels) {
                        val conf = inner[c][a].toDouble()
                        if (conf > maxConf) {
                            maxConf = conf.toDouble()
                            maxIdx = c - 4
                        }
                    }
                    if (maxConf > CONF_THRESHOLD.toDouble()) {
                        detections.add(Detection(cx, cy, w, h, maxConf, maxIdx))
                    }
                }
            } catch (e: Exception) {
                // Fallback: shape [1, 8400, 84] — try as Array<Array<FloatArray>> where
                // [0] is the batch, then [i] = [8400][84].
                try {
                    @Suppress("UNCHECKED_CAST")
                    val data2 = rawOut as Array<Array<FloatArray>>  // [1][8400][84]
                    val inner = data2[0]  // [8400][84]
                    val numAnchors = inner.size
                    val numChannels = inner[0].size
                    for (a in 0 until numAnchors) {
                        val cx = inner[a][0].toDouble()
                        val cy = inner[a][1].toDouble()
                        val w = inner[a][2].toDouble()
                        val h = inner[a][3].toDouble()
                        var maxConf = 0.0
                        var maxIdx = 0
                        for (c in 4 until numChannels) {
                            val conf = inner[a][c].toDouble().toDouble().toDouble()
                            if (conf > maxConf) {
                                maxConf = conf.toDouble()
                                maxIdx = c - 4
                            }
                        }
                        if (maxConf > CONF_THRESHOLD.toDouble()) {
                            detections.add(Detection(cx, cy, w, h, maxConf, maxIdx))
                        }
                    }
                } catch (e: Exception) {
                    return emptyList()
                }
            }

            // 6. NMS.
            val nms = nms(detections, IOU_THRESHOLD)
            // 7. Convert back to original image coords (un-letterbox).
            // YOLO boxes are in [0..640] (input space), centered.
            return nms.map { d ->
                // Un-center, scale, un-letterbox
                val realX = (((d.cx - d.w / 2.0) / scale) / origW).coerceIn(0.0, 1.0)
                val realY = (((d.cy - d.h / 2.0) / scale) / origH).coerceIn(0.0, 1.0)
                val realW = ((d.w / scale) / origW).coerceIn(0.0, 1.0)
                val realH = ((d.h / scale) / origH).coerceIn(0.0, 1.0)
                val label = if (d.clsIdx in COCO_LABELS.indices) COCO_LABELS[d.clsIdx] else "object"
                mapOf(
                    "x" to realX.toDouble(),
                    "y" to realY.toDouble(),
                    "w" to realW.toDouble(),
                    "h" to realH.toDouble(),
                    "label" to label,
                    "confidence" to d.conf.toDouble()
                )
            }
        }

        /// Non-maximum suppression.
        private fun nms(dets: List<Detection>, iouThresh: Double): List<Detection> {
            val sorted = dets.sortedByDescending { it.conf }.toMutableList()
            val keep = mutableListOf<Detection>()
            while (sorted.isNotEmpty()) {
                val best = sorted.removeAt(0)
                keep.add(best)
                val iter = sorted.iterator()
                while (iter.hasNext()) {
                    val d = iter.next()
                    if (iou(best, d) > iouThresh) iter.remove()
                }
            }
            return keep
        }

        /// Intersection-over-union for two xywh boxes.
        private fun iou(a: Detection, b: Detection): Double {
            val ax1 = a.cx - a.w / 2.0
            val ay1 = a.cy - a.h / 2.0
            val ax2 = a.cx + a.w / 2.0
            val ay2 = a.cy + a.h / 2.0
            val bx1 = b.cx - b.w / 2.0
            val by1 = b.cy - b.h / 2.0
            val bx2 = b.cx + b.w / 2.0
            val by2 = b.cy + b.h / 2.0
            val ix1 = maxOf(ax1, bx1)
            val iy1 = maxOf(ay1, by1)
            val ix2 = minOf(ax2, bx2)
            val iy2 = minOf(ay2, by2)
            val iw = maxOf(0.0, ix2 - ix1)
            val ih = maxOf(0.0, iy2 - iy1)
            val inter = iw * ih
            val union = a.w * a.h + b.w * b.h - inter
            return if (union > 0.0) inter / union else 0.0
        }

        private data class Detection(
            val cx: Double, val cy: Double, val w: Double, val h: Double,
            val conf: Double, val clsIdx: Int
        )
    }
}
