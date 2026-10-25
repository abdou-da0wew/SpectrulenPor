import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'onnx_prediction.dart';

/// Specialized on-device classifier running on **ONNX Runtime Mobile**.
///
/// Powered by flutter_onnxruntime 1.9.0 (which uses native
/// onnxruntime-android 1.28.0 — supports Android 12-17 + 16KB-page size).
///
/// Pipeline:
///   * dynamic-range quantized model (int8 weights, float I/O)
///   * 4 intra-op threads (XNNPACK-backed CPU EP)
///   * inference in a background isolate (UI never janks)
///   * preprocessing pipelined through `Isolate.run` (decode/resize/normalize)
///
/// Model assets (produced by `tooling/convert_mobilenet_onnx.py`):
///   assets/models/model.onnx      — quantized model
///   assets/models/labels.txt      — one class name per line, index order
/// If the assets are absent the service disables itself and the app falls
/// back to ML Kit / cloud tiers (Moondream3.1-9B-A2B).
class OnnxVisionService {
  OnnxVisionService._();
  static final OnnxVisionService instance = OnnxVisionService._();

  final List<String> _labels = <String>[];
  bool _isReady = false;
  bool _loading = false;
  OnnxRuntime? _ort;
  OrtSession? _session;
  int _inputSize = 224;  // standard MobileNet input

  bool get isReady => _isReady;
  int get labelCount => _labels.length;

  Future<void> init() async {
    if (_isReady || _loading) return;
    _loading = true;
    try {
      // Load labels
      try {
        final labelsStr = await rootBundle.loadString('assets/models/labels.txt');
        _labels
          ..clear()
          ..addAll(labelsStr.split('\n').where((l) => l.trim().isNotEmpty));
      } on Exception {
        // No labels file — service unavailable
        _loading = false;
        return;
      }

      // Initialize OnnxRuntime + create session from asset model
      _ort = OnnxRuntime();
      try {
        _session = await _ort!.createSessionFromAsset('assets/models/model.onnx');
      } on Exception catch (e) {
        debugPrint('[OnnxVision] model load failed: $e — falling back to cloud.');
        _ort = null;
        _loading = false;
        return;
      }

      _isReady = true;
      debugPrint('[OnnxVision] ready — ${_labels.length} labels loaded');
    } catch (e) {
      debugPrint('[OnnxVision] init failed: $e');
    } finally {
      _loading = false;
    }
  }

  Future<List<OnnxPrediction>?> classify(
    Uint8List jpegBytes, {
    int k = 3,
  }) async {
    if (!_isReady || _session == null) return null;

    try {
      // Preprocess: decode JPEG -> resize to _inputSize -> normalize -> Float32List
      final preprocessed = await Isolate.run<Float32List>(() {
        final decoded = img.decodeImage(jpegBytes);
        if (decoded == null) throw StateError('image decode failed');
        final resized = img.copyResize(decoded, width: _inputSize, height: _inputSize);
        // Normalize to [0, 1] and NCHW layout (1, 3, H, W)
        final floats = Float32List(3 * _inputSize * _inputSize);
        for (int y = 0; y < _inputSize; y++) {
          for (int x = 0; x < _inputSize; x++) {
            final p = resized.getPixel(x, y);
            final r = (p.r / 255.0).toDouble();
            final g = (p.g / 255.0).toDouble();
            final b = (p.b / 255.0).toDouble();
            // NCHW: channels-first
            floats[y * _inputSize + x] = r;
            floats[1 * _inputSize * _inputSize + y * _inputSize + x] = g;
            floats[2 * _inputSize * _inputSize + y * _inputSize + x] = b;
          }
        }
        return floats;
      });

      // Create OrtValue from Float32List with shape [1, 3, H, W]
      final inputOrt = await OrtValue.fromList(preprocessed, [1, 3, _inputSize, _inputSize]);
      final inputs = <String, OrtValue>{'input': inputOrt};

      // Run inference
      final outputs = await _session!.run(inputs);
      final outputOrt = outputs['output'];
      if (outputOrt == null) return null;
      final rawList = await outputOrt.asList();

      // rawList is typically List<double> for float32 outputs
      final List<double> probs = (rawList as List).map((e) => (e as num).toDouble()).toList();

      // Pick top-k
      final indexed = <MapEntry<int, double>>[];
      for (int i = 0; i < probs.length && i < _labels.length; i++) {
        indexed.add(MapEntry(i, probs[i]));
      }
      indexed.sort((a, b) => b.value.compareTo(a.value));
      final top = indexed.take(k).map((e) {
        final label = e.key < _labels.length ? _labels[e.key] : 'unknown';
        // OnnxPrediction(this.label, this.confidence, this.classIndex) — positional
        return OnnxPrediction(label, e.value, e.key);
      }).toList();

      return top;
    } catch (e) {
      debugPrint('[OnnxVision] classify failed: $e — falling back to cloud tier');
      return null;
    }
  }

  void dispose() {
    _session?.close();
    _session = null;
    _ort = null;
    _isReady = false;
    _labels.clear();
  }
}
