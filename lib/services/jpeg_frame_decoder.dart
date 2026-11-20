import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../models/frame_data.dart';
import 'ble_protocol.dart';

/// Assembles JPEG frames from BLE notification fragments.
///
/// Detects SOI (FFD8) and EOI (FFD9) markers, including markers that straddle
/// two notifications. Returns a completed [FrameData] when a full frame has
/// been reassembled, or null while still collecting fragments.
class JpegFrameDecoder {
  JpegFrameDecoder({int maxFrameBytes = BleProtocol.maxFrameBytes})
      : _maxFrameBytes = maxFrameBytes;

  final int _maxFrameBytes;
  final BytesBuilder _jpegBuf = BytesBuilder();
  bool _capturing = false;
  int _lastByte = -1;

  /// Bytes currently buffered for the in-progress frame.
  int get byteCount => _jpegBuf.length;

  /// Reset reassembly state, discarding any partial frame.
  void reset() {
    _jpegBuf.clear();
    _capturing = false;
    _lastByte = -1;
  }

  /// Feed a raw BLE notification chunk. Returns a completed [FrameData] when
  /// a full JPEG frame (SOI through EOI) has been reassembled, or null if more
  /// data is needed.
  FrameData? feed(Uint8List chunk) {
    if (chunk.isEmpty) return null;
    final bytes = Uint8List.fromList(chunk);

    int pos = 0;
    while (pos < bytes.length) {
      if (!_capturing) {
        // Scan for SOI (FFD8), honoring a 0xFF carried from the previous
        // notification (marker split across chunks).
        const int soiNotFound = -2;
        int soi = soiNotFound;
        if (_lastByte == 0xFF && bytes[pos] == 0xD8) {
          soi = pos - 1; // virtual: the FF lives at the end of previous chunk
          _jpegBuf.add([0xFF]);
        } else {
          for (int i = pos; i < bytes.length - 1; i++) {
            if (bytes[i] == 0xFF && bytes[i + 1] == 0xD8) {
              soi = i;
              break;
            }
          }
        }
        if (soi == soiNotFound) {
          _lastByte = bytes.last;
          return null;
        }
        _lastByte = -1;
        _capturing = true;
        pos = (soi == pos - 1) ? pos : soi;
        if (soi == pos) {
          // SOI fully inside this chunk: seed the buffer with FF D8.
          _jpegBuf.add([0xFF, 0xD8]);
          pos = soi + 2;
        }
        continue;
      }

      // Capturing: append this chunk and look for EOI.
      int frameEndInChunk = -1; // inclusive index of D9 byte
      if (_lastByte == 0xFF && bytes[pos] == 0xD9) {
        frameEndInChunk = pos; // FF already in buffer
      } else {
        for (int i = pos; i < bytes.length - 1; i++) {
          if (bytes[i] == 0xFF && bytes[i + 1] == 0xD9) {
            frameEndInChunk = i + 1;
            break;
          }
        }
      }

      if (frameEndInChunk < 0) {
        _jpegBuf.add(bytes.sublist(pos));
        _lastByte = bytes.last;
        if (_jpegBuf.length > _maxFrameBytes) {
          debugPrint('[BLE] frame exceeded max size — resetting buffer.');
          reset();
          return null;
        }
        return null;
      }

      _jpegBuf.add(bytes.sublist(pos, frameEndInChunk + 1));
      final jpeg = _jpegBuf.toBytes();
      reset();
      return FrameData(
        jpegBytes: Uint8List.fromList(jpeg),
        width: 320, // ESP32-CAM firmware streams QVGA (320x240)
        height: 240,
        capturedAt: DateTime.now(),
      );
    }
    return null;
  }
}
