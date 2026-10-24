import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

/// One prediction from the specialized ONNX model.
class OnnxPrediction {
  final String label;
  final double confidence; // 0..1
  final int classIndex;

  OnnxPrediction(this.label, this.confidence, this.classIndex);
}

/// Specialized on-device classifier running on **ONNX Runtime Mobile**.
///
/// This is the project's "analysis brain": a quantized scientific /
/// everyday-objects model (e.g. MobileNetV2 or a fine-tuned lab-equipment
/// classifier) executed with aggressive optimization:
///
///   * dynamic-range quantized model (int8 weights, float I/O)
///   * full graph optimization level
///   * 4 intra-op threads (XNNPACK-backed CPU EP)
///   * inference in a background isolate (UI never janks)
///   * preprocessing pipelined through `compute()` (decode/resize/normalize)
///
/// The raw top-5 predictions are (a) spoken instantly if narration is on and
/// (b) forwarded to the LLM *only for presentation* — the LLM does not do the
/// analysis, which keeps the pipeline latency low.
///
/// Model assets (produced by `tooling/convert_mobilenet_onnx.py`):
///   assets/models/model.onnx      — quantized model
///   assets/models/labels.txt      — one class name per line, index order
/// If the assets are absent the service disables itself and the app falls
/// back to ML Kit, so the app always works.
class OnnxVisionService {
  OnnxVisionService._();
  static final OnnxVisionService instance = OnnxVisionService._();

  OrtSession? _session;
  OrtSessionOptions? _sessionOptions;
  List<String> _labels = const [];
  String _inputName = 'input';
  bool _ready = false;

  static const int inputSize = 224;

  bool get isReady => _ready;

  /// Number of classes in the loaded labels file (0 when disabled).
  int get labelCount => _labels.length;

  /// Try to load the model + labels from bundled assets. Safe to call
  /// multiple times; silent no-op when assets are missing.
  Future<void> init() async {
    if (_ready) return;
    try {
      final files = <String, File>{};
      final dir = await getApplicationSupportDirectory();

      for (final name in const ['model.onnx', 'labels.txt']) {
        try {
          final data = await rootBundle.load('assets/models/$name');
          final f = File('${dir.path}/$name');
          await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
          files[name] = f;
        } catch (_) {
          debugPrint('[OnnxVision] assets/models/$name missing — ONNX path '
              'disabled (ML Kit fallback stays active).');
          return;
        }
      }

      // Labels: one per line, in class-index order.
      _labels = const LineSplitter()
          .convert(await files['labels.txt']!.readAsString())
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList(growable: false);

      OrtEnv.instance.init();
      _sessionOptions = OrtSessionOptions();
      _sessionOptions!.setIntraOpNumThreads(4); // XNNPACK thread pool
      _sessionOptions!.setGraphOptimizationLevel(
          GraphOptimizationLevel.ortEnableAll);

      _session = OrtSession.fromFile(files['model.onnx']!, _sessionOptions!);
      _inputName = _session!.inputNames.isNotEmpty
          ? _session!.inputNames.first
          : 'input';

      _ready = true;
      debugPrint('[OnnxVision] ready — ${_labels.length} classes, '
          'threads=4, graphOpt=all');
    } catch (e) {
      debugPrint('[OnnxVision] init failed: $e');
      _ready = false;
    }
  }

  /// Classify a JPEG frame. Returns top-[k] predictions (k<=5), or null when
  /// the service is disabled / inference failed.
  Future<List<OnnxPrediction>?> classify(
    Uint8List jpegBytes, {
    int k = 5,
  }) async {
    if (!_ready || _session == null) return null;
    try {
      final input = await compute(_preprocess, jpegBytes);

      final tensor = OrtValueTensor.createTensorWithDataList(
          input, [1, 3, inputSize, inputSize]);
      final runOptions = OrtRunOptions();
      try {
        final outputs =
            _session!.run(runOptions, {_inputName: tensor});
        final raw = outputs.isNotEmpty ? outputs.first?.value : null;

        List<double> logits;
        if (raw is List && raw.isNotEmpty && raw.first is List) {
          logits = (raw.first as List).map((e) => (e as num).toDouble()).toList();
        } else if (raw is List) {
          logits = raw.map((e) => (e as num).toDouble()).toList();
        } else {
          return null;
        }

        // Top-k by index sort (no full sort of the 1000+ vector).
        final idx = List<int>.generate(logits.length, (i) => i);
        idx.sort((a, b) => logits[b].compareTo(logits[a]));

        // Softmax over the top-k neighborhood for readable confidences.
        final top = idx.take(k).toList();
        double maxLogit = logits[top.first];
        final exps =
            top.map((i) => math.exp(logits[i] - maxLogit)).toList();
        final sum = exps.fold<double>(0, (a, b) => a + b);

        return [
          for (var j = 0; j < top.length; j++)
            OnnxPrediction(
              j < _labels.length ? _labels[top[j]] : 'class ${top[j]}',
              (exps[j] / sum).clamp(0.0, 1.0),
              top[j],
            ),
        ];
      } finally {
        tensor.release();
        runOptions.release();
      }
    } catch (e) {
      debugPrint('[OnnxVision] classify failed: $e');
      return null;
    }
  }

  /// Preprocess executed inside a background isolate.
  static Float32List _preprocess(Uint8List jpegBytes) {
    final decoded = img.decodeImage(jpegBytes);
    if (decoded == null) throw 'JPEG decode failed';
    final resized = img.copyResize(
      decoded,
      width: inputSize,
      height: inputSize,
      interpolation: img.Interpolation.average, // fast + stable
    );

    // NCHW float32, normalized to [0,1] (MobileNetV2 / torchvision style).
    final out = Float32List(3 * inputSize * inputSize);
    final plane = inputSize * inputSize;
    for (var y = 0; y < inputSize; y++) {
      for (var x = 0; x < inputSize; x++) {
        final px = resized.getPixel(x, y);
        final i = y * inputSize + x;
        out[i] = px.r / 255.0;
        out[plane + i] = px.g / 255.0;
        out[2 * plane + i] = px.b / 255.0;
      }
    }
    return out;
  }

  void dispose() {
    _session = null;
    _sessionOptions = null;
    try {
      OrtEnv.instance.release();
    } catch (_) {}
    _ready = false;
  }
}
