import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

import '../models/frame_data.dart';
import '../models/glasses_setup.dart';

/// Receives SVGA JPEG video over UDP from the ESP32-CAM glasses.
///
/// BLE (ffe0/ffe1/ffe2) commissions the WiFi profile before a WiFi-only reboot.
/// UDP (port 8888) carries SVGA (800x600) images and controls after that reboot.
///
/// Packet header (16 bytes, little-endian, ESP32-native):
///   [seq:4][total:4][offset:4][size:4][payload...]
class WifiUdpVideoService {
  WifiUdpVideoService({
    Future<RawDatagramSocket> Function()? socketFactory,
    Future<List<int>?> Function(Uint8List)? frameDecoder,
    this.frameTimeout = const Duration(seconds: 3),
    this.readinessTimeout = const Duration(seconds: 8),
    this.stalledTimeout = const Duration(seconds: 8),
  })  : _socketFactory = socketFactory ?? _bindSocket,
        _frameDecoder = frameDecoder ?? _decodeFrame;

  static const int udpVideoPort = 8888;
  static const int udpHeaderLen = 16;
  static const int udpMtuSafe = 1400;
  static const int payloadBytes = 512;
  static const int maxFrameBytes = 512 * 1024;
  static const int maxPacketCount = maxFrameBytes ~/ payloadBytes;
  static const int maxImageDimension = 1600;
  static const int maxImagePixels = 1600 * 1200;

  final Future<RawDatagramSocket> Function() _socketFactory;
  final Future<List<int>?> Function(Uint8List) _frameDecoder;
  final Duration frameTimeout;
  final Duration readinessTimeout;
  final Duration stalledTimeout;

  static Future<RawDatagramSocket> _bindSocket() =>
      RawDatagramSocket.bind(InternetAddress.anyIPv4, 0, reuseAddress: false);

  static Future<List<int>?> _decodeFrame(Uint8List jpeg) =>
      compute(_decodeJpegDimensions, jpeg);

  static InternetAddress? parsePeerAddress(String ip) {
    final address = InternetAddress.tryParse(ip);
    if (address == null || address.type != InternetAddressType.IPv4) {
      return null;
    }
    final bytes = address.rawAddress;
    if (bytes[0] == 0 ||
        bytes[0] == 127 ||
        bytes[0] >= 224 ||
        bytes.every((byte) => byte == 255)) {
      return null;
    }
    return address;
  }

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
  StreamSubscription<RawSocketEvent>? _socketSub;
  InternetAddress? _espIp;
  int _espPort = udpVideoPort;
  bool _streaming = false;
  bool _ready = false;
  bool _disposed = false;
  bool _starting = false;
  int _generation = 0;
  int? _decodingGeneration;
  Completer<void>? _firstFrame;
  Timer? _readinessTimer;
  Timer? _stalledTimer;
  GlassesFailure? lastFailure;

  // Frame reassembly state (little-endian header from ESP32)
  final Map<int, Uint8List> _framePackets = {};
  int _frameTotal = 0;
  int _nextSeq = 0;
  Timer? _frameTimeoutTimer;

  bool get isStreaming => _streaming;
  bool get isReady => _ready;
  bool get isActive => _socket != null;
  InternetAddress? get espIp => _espIp;

  /// Bind a local UDP socket, tell the ESP we're the peer (so it unicasts
  /// video to us instead of broadcasting), and start the stream.
  Future<void> start({
    required InternetAddress espIp,
    int port = udpVideoPort,
  }) async {
    if (_disposed || _starting || isActive) {
      throw const GlassesException(GlassesFailure.busy);
    }
    if (parsePeerAddress(espIp.address) == null || port <= 0 || port > 65535) {
      throw const GlassesException(GlassesFailure.invalidIp);
    }
    _starting = true;
    final generation = ++_generation;
    lastFailure = null;
    _ready = false;
    _streaming = false;
    _espIp = espIp;
    _espPort = port;
    _statusCtl.add('connecting');
    final firstFrame = Completer<void>();
    _firstFrame = firstFrame;
    unawaited(firstFrame.future.catchError((Object _) {}));
    _readinessTimer = Timer(
      readinessTimeout,
      () => _fail(GlassesFailure.udpTimeout),
    );
    try {
      // A timeout/stop must finish even if binding has not returned yet. A
      // late binding still owns a socket, so close it when it finally arrives.
      final socket = await Future.any<RawDatagramSocket>([
        _socketFactory().then((socket) {
          if (_disposed || generation != _generation) socket.close();
          return socket;
        }),
        firstFrame.future.then<RawDatagramSocket>(
          (_) => throw const GlassesException(GlassesFailure.udpUnavailable),
        ),
      ]);
      if (_disposed || generation != _generation) {
        socket.close();
        throw const GlassesException(GlassesFailure.udpUnavailable);
      }
      _socket = socket;
      socket.writeEventsEnabled = false;
      _socketSub = socket.listen(
        (event) {
          if (generation != _generation || _disposed) return;
          if (event == RawSocketEvent.closed) {
            _fail(GlassesFailure.udpUnavailable);
            return;
          }
          if (event != RawSocketEvent.read) return;
          try {
            while (true) {
              final dg = socket.receive();
              if (dg == null) break;
              // A packet cannot change the configured peer or its command target.
              if (dg.address.address == _espIp?.address &&
                  dg.port == _espPort) {
                _processPacket(dg.data);
              }
            }
          } catch (_) {
            _fail(GlassesFailure.udpUnavailable);
          }
        },
        onError: (Object _) {
          if (generation == _generation && !_disposed) {
            _fail(GlassesFailure.udpUnavailable);
          }
        },
        onDone: () {
          if (generation == _generation && !_disposed) {
            _fail(GlassesFailure.udpUnavailable);
          }
        },
      );
      _streaming = true;
      _sendRaw([cmdStreamOn]);
      await firstFrame.future;
    } on GlassesException catch (e) {
      if (generation == _generation) _fail(e.code);
      rethrow;
    } catch (_) {
      if (generation == _generation) _fail(GlassesFailure.udpUnavailable);
      throw const GlassesException(GlassesFailure.udpUnavailable);
    } finally {
      _starting = false;
    }
  }

  /// Stop streaming and close the socket.
  Future<void> stop() async {
    try {
      if (isActive) _sendRaw([cmdStreamOff]);
    } finally {
      _close();
      if (!_disposed) _statusCtl.add('disconnected');
    }
  }

  /// Send a single-byte control command to the ESP over UDP.
  void sendCommand(int cmd) {
    if (cmd < cmdStreamOff || cmd > cmdFlashOff) {
      throw const GlassesException(GlassesFailure.unsupportedControl);
    }
    _sendRaw([cmd]);
    if (cmd == cmdStreamOff) {
      _streaming = false;
      _stalledTimer?.cancel();
      _resetFrame();
      _statusCtl.add('paused');
    } else if (cmd == cmdStreamOn) {
      _streaming = true;
      _armStalledTimer();
      _statusCtl.add(_ready ? 'connected' : 'connecting');
    } else if (cmd == cmdSingleFrame) {
      // The listener remains active while paused; one frame does not resume it.
      _armStalledTimer();
    }
  }

  void _armStalledTimer() {
    _stalledTimer?.cancel();
    _stalledTimer = Timer(
      stalledTimeout,
      () => _fail(GlassesFailure.udpStalled),
    );
  }

  void _processPacket(Uint8List data) {
    if (data.length < udpHeaderLen) return;

    final header = ByteData.sublistView(data);
    final seq = header.getUint32(0, Endian.little);
    final total = header.getUint32(4, Endian.little);
    final offset = header.getUint32(8, Endian.little);
    final size = header.getUint32(12, Endian.little);
    if (total == 0 ||
        total > maxPacketCount ||
        seq >= total ||
        size == 0 ||
        size > payloadBytes ||
        data.length != udpHeaderLen + size ||
        offset != seq * payloadBytes ||
        offset + size > maxFrameBytes ||
        (seq < total - 1 && size != payloadBytes)) {
      return;
    }
    final payload = Uint8List.sublistView(data, udpHeaderLen);
    final duplicate = _framePackets[seq];
    if (duplicate != null && _frameTotal == total) {
      if (_sameBytes(duplicate, payload)) return;
      _resetFrame();
    }
    if (seq == 0) {
      // No frame ID exists on this wire. Anchor at packet zero and require the
      // firmware's ordered sequence, dropping gaps rather than mixing images.
      _resetFrame();
      _frameTotal = total;
      _frameTimeoutTimer = Timer(frameTimeout, _resetFrame);
    }
    if (_frameTotal != total || seq != _nextSeq) {
      _resetFrame();
      return;
    }
    _framePackets[seq] = Uint8List.fromList(payload);
    _nextSeq++;
    if (_nextSeq == _frameTotal) unawaited(_assembleFrame());
  }

  Future<void> _assembleFrame() async {
    final bytes = BytesBuilder();
    for (int i = 0; i < _frameTotal; i++) {
      final p = _framePackets[i];
      if (p != null) bytes.add(p);
    }
    final jpeg = bytes.toBytes();
    _resetFrame();
    if (jpeg.length < 4 ||
        jpeg[0] != 0xFF ||
        jpeg[1] != 0xD8 ||
        jpeg[jpeg.length - 2] != 0xFF ||
        jpeg.last != 0xD9) {
      return;
    }
    final generation = _generation;
    if (_decodingGeneration == generation) return;
    _decodingGeneration = generation;
    try {
      final dimensions = await _frameDecoder(jpeg);
      if (_disposed || generation != _generation || dimensions == null) return;
      _ready = true;
      _readinessTimer?.cancel();
      if (_firstFrame?.isCompleted == false) _firstFrame!.complete();
      if (_streaming) {
        _armStalledTimer();
      } else {
        _stalledTimer?.cancel();
      }
      _statusCtl.add(_streaming ? 'connected' : 'paused');
      _frameCtl.add(
        FrameData(
          jpegBytes: jpeg,
          width: dimensions[0],
          height: dimensions[1],
          capturedAt: DateTime.now(),
        ),
      );
    } catch (_) {
      // A bad image or decoder failure cannot produce readiness or reset a
      // stall deadline. Wait for a later valid frame or the existing timeout.
    } finally {
      if (_decodingGeneration == generation) _decodingGeneration = null;
    }
  }

  void _resetFrame() {
    _framePackets.clear();
    _frameTotal = 0;
    _nextSeq = 0;
    _frameTimeoutTimer?.cancel();
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _sendRaw(List<int> bytes) {
    if (_socket == null || _espIp == null) {
      throw const GlassesException(GlassesFailure.udpUnavailable);
    }
    try {
      if (_socket!.send(bytes, _espIp!, _espPort) != bytes.length) {
        throw const GlassesException(GlassesFailure.udpUnavailable);
      }
    } catch (_) {
      _fail(GlassesFailure.udpUnavailable);
      throw const GlassesException(GlassesFailure.udpUnavailable);
    }
  }

  void _close() {
    ++_generation;
    _streaming = false;
    _ready = false;
    _readinessTimer?.cancel();
    _stalledTimer?.cancel();
    _resetFrame();
    _socketSub?.cancel();
    _socketSub = null;
    _socket?.close();
    _socket = null;
    _espIp = null;
    if (_firstFrame?.isCompleted == false) {
      _firstFrame!.completeError(
        GlassesException(lastFailure ?? GlassesFailure.udpUnavailable),
      );
    }
    _firstFrame = null;
  }

  void _fail(GlassesFailure failure) {
    if (_disposed) return;
    lastFailure = failure;
    _close();
    _statusCtl.add('failed');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _close();
    _frameCtl.close();
    _statusCtl.close();
  }
}

List<int>? _decodeJpegDimensions(Uint8List jpeg) {
  try {
    final decoder = img.JpegDecoder();
    final info = decoder.startDecode(jpeg);
    if (info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width > WifiUdpVideoService.maxImageDimension ||
        info.height > WifiUdpVideoService.maxImageDimension ||
        info.width * info.height > WifiUdpVideoService.maxImagePixels) {
      return null;
    }
    final decoded = decoder.decodeFrame(0);
    return decoded == null ? null : [decoded.width, decoded.height];
  } catch (_) {
    return null;
  }
}
