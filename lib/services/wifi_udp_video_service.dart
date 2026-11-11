import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import '../models/frame_data.dart';

/// Receives SVGA JPEG video over UDP from the ESP32-CAM glasses.
///
/// Dual-connection architecture:
///   * BLE (ffe0/ffe1/ffe2)  — telemetry, commands, WiFi config, warnings
///   * WiFi + UDP (port 8888) — SVGA (800x600) JPEG video stream
///
/// Packet header (16 bytes, little-endian, ESP32-native):
///   [seq:4][total:4][offset:4][size:4][payload...]
class WifiUdpVideoService {
  static const int udpVideoPort = 8888;
  static const int udpHeaderLen = 16;
  static const int udpMtuSafe = 1400;

  // Command bytes (mirror firmware config.h)
  static const int cmdStreamOff = 0x00;
  static const int cmdStreamOn = 0x01;
  static const int cmdSingleFrame = 0x02;
  static const int cmdFlashOn = 0x03;
  static const int cmdFlashOff = 0x04;

  final StreamController<FrameData> _frameCtl =
      StreamController<FrameData>.broadcast();
  Stream<FrameData> get frameStream => _frameCtl.stream;

  final StreamController<String> _statusCtl =
      StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusCtl.stream;

  RawDatagramSocket? _socket;
  InternetAddress? _espIp;
  int _espPort = udpVideoPort;
  bool _streaming = false;

  // Frame reassembly state (little-endian header from ESP32)
  final Map<int, Uint8List> _framePackets = {};
  int _frameTotal = 0;
  Timer? _frameTimeoutTimer;

  bool get isStreaming => _streaming;
  InternetAddress? get espIp => _espIp;

  /// Bind a local UDP socket, tell the ESP we're the peer (so it unicasts
  /// video to us instead of broadcasting), and start the stream.
  Future<void> start({
    required InternetAddress espIp,
    int port = udpVideoPort,
  }) async {
    _espIp = espIp;
    _espPort = port;

    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
      reuseAddress: true,
    );
    _socket!.listen((_) {
      while (true) {
        final dg = _socket!.receive();
        if (dg == null) break;
        _espIp = dg.address; // record/re-confirm ESP IP
        _processPacket(dg.data);
      }
    });

    // Send stream-on so the ESP records our IP:port as the video destination.
    _sendRaw([cmdStreamOn]);
    _streaming = true;
    _statusCtl.add('connected');
    debugPrint('[UDP] video started to $espIp:$port');
  }

  /// Stop streaming and close the socket.
  Future<void> stop() async {
    _streaming = false;
    _sendRaw([cmdStreamOff]);
    _socket?.close();
    _socket = null;
    _espIp = null;
    _framePackets.clear();
    _frameTotal = 0;
    _frameTimeoutTimer?.cancel();
    _statusCtl.add('disconnected');
    debugPrint('[UDP] video stopped');
  }

  /// Send a single-byte control command to the ESP over UDP.
  void sendCommand(int cmd) => _sendRaw([cmd]);

  void _processPacket(Uint8List data) {
    if (data.length < udpHeaderLen) return;

    final seq = _leU32(data, 0);
    final total = _leU32(data, 4);
    final size = _leU32(data, 12);

    final payload = data.sublist(udpHeaderLen, udpHeaderLen + size);

    if (_frameTotal == 0) {
      _frameTotal = total;
      _frameTimeoutTimer?.cancel();
      _frameTimeoutTimer = Timer(const Duration(seconds: 5), _resetFrame);
    }

    _framePackets[seq] = payload;

    if (_framePackets.length == _frameTotal) {
      _assembleFrame();
    }
  }

  void _assembleFrame() {
    final bytes = BytesBuilder();
    for (int i = 0; i < _frameTotal; i++) {
      final p = _framePackets[i];
      if (p != null) bytes.add(p);
    }
    final jpeg = bytes.toBytes();

    _frameCtl.add(FrameData(
      jpegBytes: Uint8List.fromList(jpeg),
      width: 800, // SVGA
      height: 600,
      capturedAt: DateTime.now(),
    ));

    _resetFrame();
  }

  void _resetFrame() {
    _framePackets.clear();
    _frameTotal = 0;
    _frameTimeoutTimer?.cancel();
  }

  /// ESP32 (Xtensa LX6) is little-endian; read u32 accordingly.
  int _leU32(Uint8List d, int o) =>
      d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24);

  void _sendRaw(List<int> bytes) {
    if (_socket == null || _espIp == null) return;
    _socket!.send(Uint8List.fromList(bytes), _espIp!, _espPort);
  }

  void dispose() {
    _frameCtl.close();
    _statusCtl.close();
    _frameTimeoutTimer?.cancel();
    _socket?.close();
  }
}
