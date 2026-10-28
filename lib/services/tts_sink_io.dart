import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:path_provider/path_provider.dart';

/// Native-platform TTS audio sink.
///
/// `playStreamed` pipes the live HTTP byte stream straight into just_audio
/// via a [StreamAudioSource] (`sourceLength: null` -> progressive/live
/// playback starts on the FIRST chunks — we never wait for the whole file).
/// `playBytes` buffers an already-complete MP3 through a temp file with
/// audioplayers (fallback for devices where just_audio streaming fails).
class TtsSink {
  ja.AudioPlayer? _streamPlayer;
  AudioPlayer? _filePlayer;
  StreamSubscription<ja.PlayerState>? _playerStateSub;
  StreamSubscription<List<int>>? _byteSub;

  /// Flips false if just_audio streaming init fails once — afterwards all
  /// audio goes through the audioplayers file path.
  bool streamingAvailable = true;

  Future<void> playStreamed(Stream<List<int>> byteStream) async {
    try {
      _streamPlayer ??= ja.AudioPlayer();

      await _playerStateSub?.cancel();
      await _byteSub?.cancel();

      final controller = StreamController<List<int>>();
      _byteSub = byteStream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
        cancelOnError: true,
      );

      final source = _TtsStreamSource(controller.stream);
      await _streamPlayer!.setAudioSource(source);
      await _streamPlayer!.play();

      _playerStateSub = _streamPlayer!.playerStateStream.listen((state) {
        if (state.processingState == ja.ProcessingState.completed) {
          _byteSub?.cancel();
          _byteSub = null;
        }
      });
    } catch (e) {
      debugPrint('[TtsSink] streamed playback unavailable: $e');
      streamingAvailable = false;
      rethrow;
    }
  }

  Future<void> playBytes(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/tts_${DateTime.now().microsecondsSinceEpoch}.mp3';
    final f = io.File(path);
    await f.writeAsBytes(bytes, flush: true);

    _filePlayer ??= AudioPlayer();
    await _filePlayer!.play(DeviceFileSource(path));
  }

  Future<void> stop() async {
    await _playerStateSub?.cancel();
    _playerStateSub = null;
    await _byteSub?.cancel();
    _byteSub = null;
    try {
      await _streamPlayer?.stop();
    } catch (_) {}
    try {
      await _filePlayer?.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    await _streamPlayer?.dispose();
    await _filePlayer?.dispose();
  }
}

/// just_audio source that consumes a live HTTP byte stream.
class _TtsStreamSource extends ja.StreamAudioSource {
  _TtsStreamSource(this._bytes);

  final Stream<List<int>> _bytes;

  @override
  Future<ja.StreamAudioResponse> request([int? start, int? end]) async {
    return ja.StreamAudioResponse(
      sourceLength: null, // unknown -> progressive streaming
      contentLength: null,
      offset: start ?? 0,
      contentType: 'audio/mpeg',
      stream: _bytes,
    );
  }
}
