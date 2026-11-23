import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Downloads Supertonic-3 on demand and runs it through the Android ONNX bridge.
class SupertonicTtsService {
  SupertonicTtsService._();

  static final SupertonicTtsService instance = SupertonicTtsService._();

  static const _channel = MethodChannel('spectrulenpor/supertonic');
  // The upstream project moved its model weights to the archived namespace.
  // Pin the exact revision so a future repository update cannot silently
  // change tokenizer, voice-style, or ONNX tensor compatibility.
  static const _baseUrl =
      'https://huggingface.co/supertone-oss-archive/supertonic-3/resolve/aafc6e32416a594460b32413efc49d7fe4ce6d46';
  static const _minimumModelBytes = {
    'duration_predictor.onnx': 1 * 1024 * 1024,
    'text_encoder.onnx': 10 * 1024 * 1024,
    'vector_estimator.onnx': 100 * 1024 * 1024,
    'vocoder.onnx': 50 * 1024 * 1024,
    'tts.json': 1000,
    'unicode_indexer.json': 200 * 1024,
  };
  static const _modelFiles = [
    'duration_predictor.onnx',
    'text_encoder.onnx',
    'vector_estimator.onnx',
    'vocoder.onnx',
    'tts.json',
    'unicode_indexer.json',
  ];

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 25),
    receiveTimeout: const Duration(minutes: 30),
    sendTimeout: const Duration(minutes: 2),
    followRedirects: true,
    headers: const {'User-Agent': 'SpectruLenPor/5'},
  ));
  final AudioPlayer _player = AudioPlayer();

  Directory? _root;
  bool _ready = false;
  bool _downloading = false;
  bool _speaking = false;
  int _speechGeneration = 0;

  bool get isReady => _ready;
  bool get isDownloading => _downloading;
  bool get isSpeaking => _speaking;

  Future<Directory> _modelRoot() async {
    if (_root != null) return _root!;
    final support = await getApplicationSupportDirectory();
    _root = Directory('${support.path}/models/supertonic-3');
    await _root!.create(recursive: true);
    return _root!;
  }

  Future<bool> hasInstalledModels() async {
    final root = await _modelRoot();
    final onnx = Directory('${root.path}/onnx');
    final style = File('${root.path}/voice_styles/M1.json');
    final modelsValid = _minimumModelBytes.entries.every((entry) {
      final file = File('${onnx.path}/${entry.key}');
      return file.existsSync() && file.lengthSync() >= entry.value;
    });
    _ready = modelsValid && style.existsSync() && style.lengthSync() >= 1000;
    return _ready;
  }

  Future<void> downloadModels({
    void Function(String file, int received, int total)? onProgress,
  }) async {
    if (_downloading)
      throw StateError('Supertonic model download is already running.');
    _downloading = true;
    try {
      final root = await _modelRoot();
      final onnx = Directory('${root.path}/onnx')..createSync(recursive: true);
      final styles = Directory('${root.path}/voice_styles')
        ..createSync(recursive: true);

      for (final name in _modelFiles) {
        final destination = File('${onnx.path}/$name');
        final minimumBytes = _minimumModelBytes[name] ?? 1000;
        if (destination.existsSync() &&
            destination.lengthSync() >= minimumBytes) {
          continue;
        }
        if (destination.existsSync()) await destination.delete();
        await _download(
          '$_baseUrl/onnx/$name',
          destination,
          onProgress: (received, total) =>
              onProgress?.call(name, received, total),
        );
        if (destination.lengthSync() < minimumBytes) {
          await destination.delete();
          throw StateError('Incomplete Supertonic model file: $name');
        }
      }

      final style = File('${styles.path}/M1.json');
      if (!style.existsSync() || style.lengthSync() < 1000) {
        await _download(
          '$_baseUrl/voice_styles/M1.json',
          style,
          onProgress: (received, total) =>
              onProgress?.call('M1 voice style', received, total),
        );
      }
      _ready = await hasInstalledModels();
      if (!_ready)
        throw StateError(
            'Supertonic files did not pass the installation check.');
    } finally {
      _downloading = false;
    }
  }

  Future<void> _download(
    String url,
    File destination, {
    void Function(int received, int total)? onProgress,
  }) async {
    await destination.parent.create(recursive: true);
    final temporary = File('${destination.path}.part');
    if (temporary.existsSync()) await temporary.delete();
    try {
      await _dio.download(
        url,
        temporary.path,
        deleteOnError: true,
        onReceiveProgress: onProgress,
      );
      if (!temporary.existsSync() || temporary.lengthSync() == 0) {
        throw StateError('The server returned an empty model file.');
      }
      if (destination.existsSync()) await destination.delete();
      await temporary.rename(destination.path);
    } catch (_) {
      if (temporary.existsSync()) await temporary.delete();
      rethrow;
    }
  }

  /// Runs native ONNX inference without playing the generated audio. This is
  /// used by the benchmark lab to measure cold/warm synthesis latency and
  /// real-time factor without disrupting the user's audio session.
  Future<Map<String, dynamic>?> benchmarkSynthesis(
    String text, {
    String? languageCode,
    int inferenceSteps = 5,
    double speed = 1.0,
  }) async {
    if (!Platform.isAndroid || text.trim().isEmpty) return null;
    if (!await hasInstalledModels()) return null;

    final root = await _modelRoot();
    final stopwatch = Stopwatch()..start();
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'synthesize',
      {
        'text': _cleanText(text),
        'language': _resolveLanguage(text, languageCode),
        'modelDirectory': '${root.path}/onnx',
        'styleFile': '${root.path}/voice_styles/M1.json',
        'steps': inferenceSteps,
        'speed': speed,
      },
    );
    stopwatch.stop();

    final outputPath = result?['path'] as String?;
    final outputFile = outputPath == null ? null : File(outputPath);
    final outputBytes = outputFile != null && await outputFile.exists()
        ? await outputFile.length()
        : 0;
    final audioDurationMs = (result?['durationMs'] as num?)?.toDouble() ?? 0;
    if (outputFile != null && await outputFile.exists()) {
      await outputFile.delete();
    }

    return {
      'latencyMs': stopwatch.elapsedMilliseconds,
      'audioDurationMs': audioDurationMs,
      'sampleRate': result?['sampleRate'],
      'outputBytes': outputBytes,
      'realTimeFactor': audioDurationMs <= 0
          ? null
          : stopwatch.elapsedMilliseconds / audioDurationMs,
      'language': _resolveLanguage(text, languageCode),
      'inferenceSteps': inferenceSteps,
      'speed': speed,
    };
  }

  Future<bool> speak(
    String text, {
    String? languageCode,
    int inferenceSteps = 5,
    double speed = 1.0,
    void Function(String file, int received, int total)? onDownloadProgress,
  }) async {
    if (!Platform.isAndroid || text.trim().isEmpty) return false;
    final generation = ++_speechGeneration;
    File? outputFile;
    try {
      if (!await hasInstalledModels()) {
        await downloadModels(onProgress: onDownloadProgress);
      }
      if (generation != _speechGeneration) return false;
      final root = await _modelRoot();
      final language = _resolveLanguage(text, languageCode);
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'synthesize',
        {
          'text': _cleanText(text),
          'language': language,
          'modelDirectory': '${root.path}/onnx',
          'styleFile': '${root.path}/voice_styles/M1.json',
          'steps': inferenceSteps,
          'speed': speed,
        },
      );
      final path = result?['path'] as String?;
      if (path != null) outputFile = File(path);
      if (generation != _speechGeneration) return false;
      if (outputFile == null || !outputFile.existsSync()) {
        throw StateError('Supertonic did not return a valid audio file.');
      }
      await _player.stop();
      if (generation != _speechGeneration) return false;
      _speaking = true;
      final playbackEnded = _player.onPlayerStateChanged.firstWhere(
        (state) =>
            state == PlayerState.completed || state == PlayerState.stopped,
      );
      await _player.play(DeviceFileSource(outputFile.path));
      await playbackEnded.timeout(const Duration(minutes: 2));
      return generation == _speechGeneration;
    } on PlatformException catch (error) {
      debugPrint('[Supertonic] Native inference failed: ${error.message}');
      return false;
    } catch (error, stackTrace) {
      debugPrint('[Supertonic] $error\n$stackTrace');
      return false;
    } finally {
      if (outputFile != null && outputFile.existsSync()) {
        try {
          await outputFile.delete();
        } catch (error) {
          debugPrint('[Supertonic] Temporary audio cleanup failed: $error');
        }
      }
      if (generation == _speechGeneration) _speaking = false;
    }
  }

  String _resolveLanguage(String text, String? locale) {
    if (RegExp(r'[\u0600-\u06FF]').hasMatch(text)) return 'ar';
    final code = locale?.toLowerCase().split(RegExp('[-_]')).first;
    return code == 'ar' ? 'ar' : 'en';
  }

  String _cleanText(String text) => text
      .replaceAll(RegExp(r'\x60{3}[\s\S]*?\x60{3}'), ' ')
      .replaceAll(RegExp(r'\x60([^\x60]+)\x60'), r'$1')
      .replaceAll(RegExp(r'[*_#>]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<void> stop() async {
    _speechGeneration++;
    try {
      await _player.stop();
    } catch (_) {}
    _speaking = false;
  }

  Future<void> releaseModels() async {
    await stop();
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<void>('release');
      } catch (error) {
        debugPrint('[Supertonic] Release warning: $error');
      }
    }
    _ready = false;
  }

  Future<void> dispose() async {
    await stop();
    await _player.dispose();
  }
}
