import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

/// Web TTS audio sink (browser preview build).
///
/// Browsers can't feed a progressive MP3 byte stream into the media element,
/// so `playStreamed` buffers the chunks and plays via a blob: URL — same
/// audible result for the preview, with identical call sites.
class TtsSink {
  AudioPlayer? _player;

  final bool streamingAvailable = false;

  Future<void> playStreamed(Stream<List<int>> byteStream) async {
    final chunks = <int>[];
    await for (final c in byteStream) {
      chunks.addAll(c);
    }
    if (chunks.isEmpty) return;
    await playBytes(Uint8List.fromList(chunks));
  }

  Future<void> playBytes(Uint8List bytes) async {
    final blob = html.Blob([bytes], 'audio/mpeg');
    final url = html.Url.createObjectUrlFromBlob(blob);
    _player ??= AudioPlayer();
    await _player!.setAudioSource(AudioSource.uri(Uri.parse(url)));
    await _player!.play();
  }

  Future<void> stop() async {
    try {
      await _player?.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await _player?.dispose();
  }
}
