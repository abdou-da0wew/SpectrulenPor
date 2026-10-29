import 'dart:typed_data';

/// One decoded frame coming from the ESP32-CAM over Bluetooth.
///
/// The ESP32-CAM typically streams JPEG-over-BLE in chunks of ~180 bytes
/// (BLE MTU is ~180-512 bytes). We reassemble them into a single JPEG buffer
/// before exposing it to the rest of the pipeline.
class FrameData {
  final Uint8List jpegBytes;
  final int width;
  final int height;
  final DateTime capturedAt;
  final int sequence;

  FrameData({
    required this.jpegBytes,
    required this.width,
    required this.height,
    required this.capturedAt,
    this.sequence = 0,
  });

  /// JPEG byte size in KB (for throttling / debug display).
  int get sizeKb => (jpegBytes.length / 1024).round();
}
