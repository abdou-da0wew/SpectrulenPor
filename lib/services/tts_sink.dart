/// Conditional TTS audio sink:
///   * VM / Android / iOS -> tts_sink_io.dart (just_audio progressive
///     StreamAudioSource + audioplayers file fallback)
///   * Web (browser preview) -> tts_sink_web.dart (blob URL playback)
export 'tts_sink_io.dart' if (dart.library.html) 'tts_sink_web.dart';
