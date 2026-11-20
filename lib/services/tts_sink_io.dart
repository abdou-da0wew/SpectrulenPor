import 'dart:async';
import 'dart:io' as io;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:path_provider/path_provider.dart';

// The streamed TTS pipeline intentionally builds on just_audio's experimental
// StreamAudioSource/StreamAudioResponse API — it is the only way to feed a
// live HTTP byte stream into the player without buffering the whole clip.
// ignore_for_file: experimental_member_use

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
  StreamSubscription<PlayerState>? _filePlayerStateSub;
  StreamSubscription<List<int>>? _byteSub;
  Completer<void>? _filePlaybackEnded;

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
      final completed = _streamPlayer!.processingStateStream.firstWhere(
        (state) => state == ja.ProcessingState.completed,
      );
      await _streamPlayer!.play();
      // Keep segments sequential. Returning before completion caused the next
      // Fish Audio sentence to replace the one that was still playing.
      await completed.timeout(const Duration(seconds: 75));
      await _byteSub?.cancel();
      _byteSub = null;
    } catch (e) {
      debugPrint('[TtsSink] streamed playback unavailable: $e');
      streamingAvailable = false;
      rethrow;
    }
  }

  Future<void> playBytes(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/tts_${DateTime.now().microsecondsSinceEpoch}.mp3';
    final file = io.File(path);
    await file.writeAsBytes(bytes, flush: true);

    _filePlayer ??= AudioPlayer();
    final player = _filePlayer!;
    await _filePlayerStateSub?.cancel();
    _filePlayerStateSub = null;
    await player.stop();

    final completed = Completer<void>();
    _filePlaybackEnded = completed;
    _filePlayerStateSub = player.onPlayerStateChanged.listen((state) {
      if ((state == PlayerState.completed || state == PlayerState.stopped) &&
          !completed.isCompleted) {
        completed.complete();
      }
    });

    try {
      await player.play(DeviceFileSource(path));
      await completed.future.timeout(const Duration(seconds: 75));
    } finally {
      await _filePlayerStateSub?.cancel();
      _filePlayerStateSub = null;
      if (identical(_filePlaybackEnded, completed)) {
        _filePlaybackEnded = null;
      }
      if (file.existsSync()) {
        try {
          await file.delete();
        } catch (error) {
          debugPrint('[TtsSink] temporary audio cleanup failed: $error');
        }
      }
    }
  }

  Future<void> stop() async {
    final filePlayback = _filePlaybackEnded;
    if (filePlayback != null && !filePlayback.isCompleted) {
      filePlayback.complete();
    }
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
