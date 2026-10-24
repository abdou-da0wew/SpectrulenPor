import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

import 'onnx_prediction.dart';

/// Specialized on-device classifier running on **ONNX Runtime Mobile**.
///
/// This is the project's offline "analysis brain": a quantized scientific /
/// everyday-objects model (e.g. MobileNetV2 or a fine-tuned lab-equipment
/// classifier) executed with aggressive optimization:
///
///   * dynamic-range quantized model (int8 weights, float I/O)
///   * full graph optimization level
///   * 4 intra-op threads (XNNPACK-backed CPU EP)
///   * inference in a background isolate (UI never janks)
///   * preprocessing pipelined through `Isolate.run` (decode/resize/normalize)
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
      _sessionOptions = OrtSessionOptions()
        ..setIntraOpNumThreads(4)
        ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);

      _session = OrtSession.fromFile(files['model.onnx']!, _sessionOptions!);
      _inputName = _session?.inputNames.first ?? 'input';
      _ready = _session != null;
      debugPrint('[OnnxVision] ready — ${_labels.length} classes, '
          'input=$_inputName.');
    } catch (e) {
      debugPrint('[OnnxVision] init failed: $e — disabled.');
      _ready = false;
    }
  }

  /// Top-k classification, or null when the engine is disabled/failed.
  Future<List<OnnxPrediction>?> classify(
    Uint8List jpegBytes, {
    int k = 3,
  }) async {
    if (!_ready || _session == null) return null;
    try {
      final tensorData = await Isolate.run(() => _preprocess(jpegBytes));
      if (tensorData == null) return null;

      final input = OrtValueTensor.createTensorWithDataList(
          tensorData, [1, 3, inputSize, inputSize]);
      final outputs = _session!.run(OrtRunOptions(), {_inputName: input});

      final logits = outputs.first?.value;
      input.release();
      for (final o in outputs) {
        o?.release();
      }

      if (logits is! List) return null;
      final scores = _softmax(logits.cast<num>());
      final ranked = List<int>.generate(scores.length, (i) => i)
        ..sort((a, b) => scores[b].compareTo(scores[a]));

      return ranked
          .take(k)
          .map((i) => OnnxPrediction(
                i < _labels.length ? _labels[i] : 'class_$i',
                scores[i],
                i,
              ))
          .toList(growable: false);
    } catch (e) {
      debugPrint('[OnnxVision] classify failed: $e');
      return null;
    }
  }

  /// Decode -> resize 224 -> normalize ImageNet -> NCHW float32 buffer.
  static Float32List? _preprocess(Uint8List jpegBytes) {
    try {
      final decoded = img.decodeJpg(jpegBytes);
      if (decoded == null) return null;
      final resized = img.copyResize(
        decoded,
        width: inputSize,
        height: inputSize,
      );

      const mean = [0.485, 0.456, 0.406];
      const std = [0.229, 0.224, 0.225];
      final out = Float32List(3 * inputSize * inputSize);
      var idx = 0;
      for (var c = 0; c < 3; c++) {
        for (var y = 0; y < inputSize; y++) {
          for (var x = 0; x < inputSize; x++) {
            final px = resized.getPixel(x, y);
            final v = switch (c) {
              0 => px.r,
              1 => px.g,
              _ => px.b,
            } /
                255.0;
            out[idx++] = ((v - mean[c]) / std[c]).toDouble();
          }
        }
      }
      return out;
    } catch (e) {
      debugPrint('[OnnxVision] preprocess failed: $e');
      return null;
    }
  }

  static List<double> _softmax(List<num> xs) {
    final maxV = xs.fold<double>(0, (a, b) => math.max(a, b.toDouble()));
    final exps = xs.map((x) => math.exp(x.toDouble() - maxV)).toList();
    final sum = exps.fold<double>(0, (a, b) => a + b);
    return exps.map((e) => e / sum).toList(growable: false);
  }

  void dispose() {
    _session?.release();
    _sessionOptions?.release();
    _ready = false;
  }
}
