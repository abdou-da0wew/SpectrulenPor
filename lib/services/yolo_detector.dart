import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/bounding_box.dart';
import 'internal_db_service.dart';

/// Diagnostic status of the on-device YOLO26-Nano ONNX model.
class YoloModelStatus {
  final bool ready;
  final String modelSource; // bundled_asset | cached_local | auto_downloaded | uninitialized
  final String modelPath;
  final int modelSizeBytes;
  final bool end2end;
  final int lastInferenceMs;
  final String inputShape;
  final String outputShape;
  final int labelCount;

  const YoloModelStatus({
    required this.ready,
    required this.modelSource,
    required this.modelPath,
    required this.modelSizeBytes,
    required this.end2end,
    required this.lastInferenceMs,
    required this.inputShape,
    required this.outputShape,
    required this.labelCount,
  });

  factory YoloModelStatus.fromMap(Map<dynamic, dynamic> m) {
    return YoloModelStatus(
      ready: m['ready'] == true,
      modelSource: (m['modelSource'] as String?) ?? 'unknown',
      modelPath: (m['modelPath'] as String?) ?? '',
      modelSizeBytes: (m['modelSizeBytes'] as num?)?.toInt() ?? 0,
      end2end: m['end2end'] != false,
      lastInferenceMs: (m['lastInferenceMs'] as num?)?.toInt() ?? 0,
      inputShape: (m['inputShape'] as String?) ?? '[1, 3, 640, 640]',
      outputShape: (m['outputShape'] as String?) ?? '[1, 300, 6]',
      labelCount: (m['labelCount'] as num?)?.toInt() ?? 80,
    );
  }
}

/// YOLO26-Nano on-device object detector — runs natively via
/// `YoloInferenceChannel` (Kotlin + ONNX Runtime Android 1.22).
///
/// Provisioning:
///   * On first startup after installation, `ensureModel()` extracts the
///     bundled `assets/models/yolo26n.onnx` (5.04 MB, Ultralytics YOLO26n
///     end-to-end `[1, 300, 6]` ONNX graph) into app internal storage, or
///     automatically downloads it if absent.
///   * YOLO26-Nano is **always local on-device** — unaffected by the
///     "Cloud-only models (except YOLO)" toggle.
class YoloDetector {
  YoloDetector._();
  static final YoloDetector instance = YoloDetector._();

  static const MethodChannel _channel = MethodChannel('com.spectraglass/yolo');

  bool _ready = false;
  bool get isReady => _ready;
  String get backendName => 'yolo26nano';

  YoloModelStatus _status = const YoloModelStatus(
    ready: false,
    modelSource: 'uninitialized',
    modelPath: '',
    modelSizeBytes: 0,
    end2end: true,
    lastInferenceMs: 0,
    inputShape: '[1, 3, 640, 640]',
    outputShape: '[1, 300, 6]',
    labelCount: 80,
  );
  YoloModelStatus get status => _status;

  List<String>? _labels;
  List<String> get labels => _labels ?? const [];

  double confidenceThreshold = 0.25;

  Future<void> init() async {
    if (_ready) return;
    await ensureModel();
  }

  /// Ensures `yolo26n.onnx` is provisioned (bundled extraction on first install
  /// or HTTPS auto-download fallback) and initializes the ONNX Runtime session.
  Future<YoloModelStatus> ensureModel({
    bool forceDownload = false,
    String? downloadUrl,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final rawStatus = await _channel.invokeMapMethod<String, dynamic>(
        'ensureModel',
        {
          'forceDownload': forceDownload,
          if (downloadUrl != null && downloadUrl.trim().isNotEmpty)
            'downloadUrl': downloadUrl.trim(),
        },
      );
      if (rawStatus != null) {
        _status = YoloModelStatus.fromMap(rawStatus);
        _ready = _status.ready;
      } else {
        final ok = await _channel.invokeMethod<bool>('init');
        _ready = ok == true;
      }
      if (_ready) {
        try {
          final l = await _channel.invokeMethod<List<dynamic>>('labels');
          _labels = l?.map((e) => e.toString()).toList() ?? const [];
        } catch (_) {}
        debugPrint(
          '[YoloDetector] ready (${_status.modelSource}) — '
          '${(_status.modelSizeBytes / 1024).round()} KB, '
          '${_labels?.length ?? _status.labelCount} classes in ${sw.elapsedMilliseconds}ms',
        );
        unawaited(InternalDatabaseService.instance.logInfo(
          'YoloDetector',
          'YOLO26-Nano initialized (${_status.modelSource})',
          {
            'sizeBytes': _status.modelSizeBytes,
            'end2end': _status.end2end,
            'outputShape': _status.outputShape,
            'initMs': sw.elapsedMilliseconds,
          },
        ));
      }
    } on MissingPluginException {
      debugPrint('[YoloDetector] native channel not registered (non-Android host)');
    } catch (e, st) {
      debugPrint('[YoloDetector] ensureModel failed: $e');
      unawaited(InternalDatabaseService.instance.logError(
        'YoloDetector',
        'YOLO26-Nano provisioning/init failed',
        error: e,
        stackTrace: st,
      ));
    } finally {
      sw.stop();
    }
    return _status;
  }

  Future<YoloModelStatus> refreshStatus() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('status');
      if (raw != null) {
        _status = YoloModelStatus.fromMap(raw);
        _ready = _status.ready;
      }
    } catch (_) {}
    return _status;
  }

  /// Run detection on a JPEG. Boxes are normalized 0..1 in original-image
  /// coordinates; `BoundingBoxOverlay` maps them via `BoxFit.cover` geometry.
  Future<List<BoundingBox>> detect(Uint8List jpegBytes) async {
    if (!_ready || jpegBytes.isEmpty) return const [];
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final sw = Stopwatch()..start();
    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'detect',
        <String, dynamic>{
          'jpgBytes': jpegBytes,
          'confThreshold': confidenceThreshold,
        },
      );
      sw.stop();
      if (result == null) return const [];
      final boxes = <BoundingBox>[];
      for (final e in result) {
        if (e is Map) {
          final x = (e['x'] as num?)?.toDouble() ?? 0.0;
          final y = (e['y'] as num?)?.toDouble() ?? 0.0;
          final w = (e['w'] as num?)?.toDouble() ?? 0.0;
          final h = (e['h'] as num?)?.toDouble() ?? 0.0;
          final label = (e['label'] as String?) ?? 'object';
          final conf = (e['confidence'] as num?)?.toDouble() ?? 0.0;
          if (w > 0 && h > 0) {
            boxes.add(BoundingBox(
              x: x,
              y: y,
              w: w,
              h: h,
              label: label,
              confidence: conf,
            ));
          }
        }
      }
      unawaited(InternalDatabaseService.instance.recordSpan(
        traceId: 'yolo_$startedAt',
        spanName: 'yolo.detect',
        startedAtMs: startedAt,
        durationMs: sw.elapsedMilliseconds,
        status: 'ok',
        attributes: {'boxCount': boxes.length},
      ));
      return boxes;
    } catch (e, st) {
      sw.stop();
      debugPrint('[YoloDetector] detect failed: $e');
      unawaited(InternalDatabaseService.instance.logError(
        'YoloDetector',
        'Frame detection failed',
        error: e,
        stackTrace: st,
      ));
      return const [];
    }
  }

  void dispose() {
    _ready = false;
    _labels = null;
  }
}
