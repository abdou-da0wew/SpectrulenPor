import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

import '../models/frame_data.dart';
import '../models/glasses_setup.dart';

/// Receives SVGA JPEG video over UDP from the ESP32-CAM glasses.
///
/// BLE is commissioning/control-only. Camera frames and runtime commands are
/// carried exclusively over UDP after the ESP32 joins the configured AP.
/// UDP (port 8888) carries V2 JPEG fragments and runtime control/status text.
///
/// Device authorship is exposed separately through BLE scan-response metadata;
/// it is intentionally not appended to UDP datagrams or the V2 frame header.
///
/// Video data uses a 24-byte little-endian header: six uint32 fields for
/// sequence, fragment count, byte offset, payload size, frame ID and frame size.
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
  static const int udpHeaderLen = 24;
  static const int udpMtuSafe = 1280;
  static const int payloadBytes = 1200;
  static const int fecGroupSize = 4;
  static const int paritySequenceFlag = 0x80000000;
  static const int paritySequenceMask = 0x7fffffff;
  static const int maxFrameBytes = 512 * 1024;
  static const int maxPacketCount =
      (maxFrameBytes + payloadBytes - 1) ~/ payloadBytes;
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
  static const int cmdRestart = 0x05;
  static const int cmdShutdown = 0x06;
  static const int cmdConnectionStatus = 0x09;
  static const int cmdReboot = 0x0B;
  static const int cmdPeerKeepalive = 0x0C;

  final StreamController<FrameData> _frameCtl =
      StreamController<FrameData>.broadcast();
  Stream<FrameData> get frameStream => _frameCtl.stream;

  final StreamController<String> _statusCtl =
      StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusCtl.stream;

  final StreamController<String> _responseCtl =
      StreamController<String>.broadcast();
  Stream<String> get responseStream => _responseCtl.stream;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSub;
  InternetAddress? _espIp;
  int _espPort = udpVideoPort;
  bool _streaming = false;
  bool _ready = false;
  bool _disposed = false;
  bool _starting = false;
  bool _peerRegistered = false;
  int _generation = 0;
  int _videoGeneration = 0;
  int? _decodingGeneration;
  Completer<void>? _firstFrame;
  Timer? _readinessTimer;
  Timer? _stalledTimer;
  Timer? _peerTimer;
  Timer? _discoveryRetryTimer;
  Timer? _reconnectTimer;
  bool _discovering = false;
  bool _rediscoveryInFlight = false;
  bool _autoReconnect = false;
  bool _autoResumeStreaming = false;
  bool _reconnectInFlight = false;
  int _reconnectAttempts = 0;
  String? _lastPeerAddress;
  GlassesFailure? lastFailure;

  // V2 frame reassembly: accept reordering and recover one lost data packet
  // from each of four interleaved sequence classes using XOR parity.
  final Map<int, Uint8List> _framePackets = {};
  final Map<int, Uint8List> _frameParity = {};
  int _frameTotal = 0;
  int _frameSize = 0;
  int? _frameId;
  int? _lastFrameId;
  Timer? _frameTimeoutTimer;

  bool get isStreaming => _streaming;
  bool get isReady => _ready;
  bool get isActive => _socket != null;
  bool get isConnected => _socket != null && _peerRegistered;
  InternetAddress? get espIp => _espIp;

  /// Open the Wi-Fi command channel without starting the camera.
  ///
  /// A keepalive registers this phone's ephemeral UDP source port as the ESP
  /// peer. All runtime commands and all video then share this socket.
  Future<void> connect({
    InternetAddress? espIp,
    int port = udpVideoPort,
  }) async {
    if (_disposed || _starting) {
      throw const GlassesException(GlassesFailure.busy);
    }
    if ((espIp != null && parsePeerAddress(espIp.address) == null) ||
        port <= 0 ||
        port > 65535) {
      throw const GlassesException(GlassesFailure.invalidIp);
    }
    if (_socket != null) {
      if ((espIp == null || _espIp?.address == espIp.address) &&
          _espPort == port &&
          _peerRegistered) {
        return;
      }
      throw const GlassesException(GlassesFailure.busy);
    }

    _starting = true;
    _autoReconnect = true;
    _lastPeerAddress = espIp?.address ?? _lastPeerAddress;
    final generation = ++_generation;
    lastFailure = null;
    _ready = false;
    _streaming = false;
    _espIp = espIp;
    _espPort = port;
    _discovering = espIp == null;
    _statusCtl.add('connecting');

    try {
      final socket = await _socketFactory().then((socket) {
        if (_disposed || generation != _generation) socket.close();
        return socket;
      }).timeout(readinessTimeout);
      if (_disposed || generation != _generation) {
        socket.close();
        throw const GlassesException(GlassesFailure.udpUnavailable);
      }
      _socket = socket;
      socket.writeEventsEnabled = false;
      if (_discovering) socket.broadcastEnabled = true;
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
              final datagram = socket.receive();
              if (datagram == null) break;
              if (_discovering && datagram.port == _espPort) {
                final isPeerEcho = datagram.data.length == 1 &&
                    datagram.data.single == cmdPeerKeepalive;
                final text =
                    utf8.decode(datagram.data, allowMalformed: true).trim();
                if (isPeerEcho || text.startsWith(r'$CMD:keepalive')) {
                  _espIp = datagram.address;
                  _discovering = false;
                }
              }
              if (datagram.address.address == _espIp?.address &&
                  datagram.port == _espPort) {
                _processPacket(datagram.data);
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

      // Subscribe before sending so even an immediate ESP reply is observed.
      final registered = responseStream
          .firstWhere((response) => response == r'$CMD:keepalive')
          .then((_) => true)
          .catchError((Object _) => false)
          .timeout(
            const Duration(seconds: 4),
            onTimeout: () => false,
          );
      final registrationClock = Stopwatch()..start();
      var acknowledged = false;
      while (!acknowledged) {
        if (_discovering) {
          final sent = _socket!.send(
            [cmdPeerKeepalive],
            InternetAddress('255.255.255.255'),
            _espPort,
          );
          if (sent != 1) {
            throw const GlassesException(GlassesFailure.udpUnavailable);
          }
        } else {
          _sendRaw([cmdPeerKeepalive]);
        }
        acknowledged = await registered.timeout(
          const Duration(milliseconds: 350),
          onTimeout: () => false,
        );
        if (!acknowledged) {
          if (registrationClock.elapsed >= const Duration(seconds: 4)) {
            throw const GlassesException(GlassesFailure.udpTimeout);
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      if (_disposed || generation != _generation || _socket == null) {
        throw const GlassesException(GlassesFailure.udpUnavailable);
      }
      if (_espIp == null) {
        throw const GlassesException(GlassesFailure.udpTimeout);
      }
      _discovering = false;
      _peerRegistered = true;
      _lastPeerAddress = _espIp!.address;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _reconnectAttempts = 0;
      _statusCtl.add('connected');
      _armPeerKeepalive();
    } on TimeoutException {
      lastFailure = GlassesFailure.udpTimeout;
      _close();
      _statusCtl.add('failed');
      if (_autoReconnect) _scheduleReconnect();
      throw const GlassesException(GlassesFailure.udpTimeout);
    } on GlassesException {
      rethrow;
    } catch (_) {
      if (generation == _generation) {
        _fail(GlassesFailure.udpUnavailable);
      }
      throw const GlassesException(GlassesFailure.udpUnavailable);
    } finally {
      _starting = false;
    }
  }

  /// Start video on an already registered UDP command channel.
  Future<void> start({
    InternetAddress? espIp,
    int port = udpVideoPort,
  }) async {
    if (_disposed || _starting) {
      throw const GlassesException(GlassesFailure.busy);
    }
    _autoReconnect = true;
    _autoResumeStreaming = true;
    if (_socket == null) {
      if (espIp == null) {
        await connect(port: port);
      } else {
        try {
          await connect(espIp: espIp, port: port);
        } catch (_) {
          // A saved DHCP address may be stale. Discover the camera on the
          // current LAN before giving up on the start request.
          await connect(port: port);
        }
      }
    } else if ((espIp != null && _espIp?.address != espIp.address) ||
        _espPort != port ||
        _espIp == null) {
      throw const GlassesException(GlassesFailure.busy);
    }
    if (_streaming && _ready) return;

    final generation = _generation;
    final firstFrame = Completer<void>();
    _firstFrame = firstFrame;
    unawaited(firstFrame.future.catchError((Object _) {}));
    _readinessTimer?.cancel();
    _readinessTimer = Timer(readinessTimeout, () {
      if (_disposed || generation != _generation || firstFrame.isCompleted) {
        return;
      }
      lastFailure = GlassesFailure.udpTimeout;
      _streaming = false;
      _ready = false;
      _statusCtl.add('failed');
      firstFrame.completeError(
        const GlassesException(GlassesFailure.udpTimeout),
      );
    });

    _streaming = true;
    _statusCtl.add('connecting');
    try {
      _sendRaw([cmdStreamOn]);
      _armPeerKeepalive();
      await firstFrame.future;
    } on GlassesException catch (error) {
      if (generation == _generation &&
          error.code != GlassesFailure.udpTimeout) {
        _fail(error.code);
      } else if (_autoResumeStreaming && !_disposed) {
        if (_socket != null) {
          _streaming = true;
          unawaited(_rediscoverPeer());
        } else {
          _scheduleReconnect();
        }
      }
      rethrow;
    } catch (_) {
      if (generation == _generation && !_disposed) {
        _fail(GlassesFailure.udpUnavailable);
      }
      throw const GlassesException(GlassesFailure.udpUnavailable);
    } finally {
      if (identical(_firstFrame, firstFrame)) {
        _firstFrame = null;
      }
    }
  }

  /// Pause camera capture but keep the UDP command socket and peer alive.
  Future<void> pause() async {
    _autoResumeStreaming = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (_socket == null) return;
    _sendRaw([cmdStreamOff]);
    _streaming = false;
    ++_videoGeneration;
    _readinessTimer?.cancel();
    _stalledTimer?.cancel();
    _discoveryRetryTimer?.cancel();
    _discoveryRetryTimer = null;
    _discovering = false;
    _resetFrame();
    _statusCtl.add('paused');
  }

  /// Compatibility alias: stopping video does not disconnect UDP controls.
  Future<void> stop() async {
    if (_starting && _socket == null) {
      await disconnect();
      return;
    }
    await pause();
  }

  /// Close the Wi-Fi transport entirely. Use only when leaving the device.
  Future<void> disconnect() async {
    _autoReconnect = false;
    _autoResumeStreaming = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    if (_socket != null && _streaming) {
      try {
        _sendRaw([cmdStreamOff]);
      } catch (_) {
        // Socket failure cleanup is already handled by _sendRaw.
      }
    }
    _close();
    if (!_disposed) _statusCtl.add('disconnected');
  }

  /// Send a single-byte runtime command on the registered UDP channel.
  void sendCommand(int cmd) {
    const supported = <int>{
      cmdStreamOff,
      cmdStreamOn,
      cmdSingleFrame,
      cmdFlashOn,
      cmdFlashOff,
      cmdRestart,
      cmdShutdown,
      cmdConnectionStatus,
      cmdReboot,
      cmdPeerKeepalive,
    };
    if (!supported.contains(cmd)) {
      throw const GlassesException(GlassesFailure.unsupportedControl);
    }
    if (!isConnected) {
      throw const GlassesException(GlassesFailure.udpUnavailable);
    }

    _sendRaw([cmd]);
    if (cmd == cmdStreamOff) {
      _autoResumeStreaming = false;
      _streaming = false;
      _stalledTimer?.cancel();
      _readinessTimer?.cancel();
      _resetFrame();
      _statusCtl.add('paused');
    } else if (cmd == cmdStreamOn) {
      _autoReconnect = true;
      _autoResumeStreaming = true;
      _streaming = true;
      _armStalledTimer();
      _statusCtl.add(_ready ? 'connected' : 'connecting');
    } else if (cmd == cmdSingleFrame) {
      _armStalledTimer();
    }
  }

  /// Query device status over the registered UDP runtime channel.
  Future<String> requestStatus({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    if (!isConnected) {
      throw const GlassesException(GlassesFailure.udpUnavailable);
    }
    final response = responseStream
        .firstWhere((value) => value.startsWith(r'$STATUS:'))
        .timeout(timeout);
    sendCommand(cmdConnectionStatus);
    try {
      return await response;
    } on TimeoutException {
      throw const GlassesException(GlassesFailure.udpTimeout);
    }
  }

  /// Send a runtime command and wait for its exact text acknowledgement.
  Future<String> sendCommandAndWait(
    int cmd, {
    required String acknowledgment,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    if (!isConnected) {
      throw const GlassesException(GlassesFailure.udpUnavailable);
    }
    final response = responseStream
        .firstWhere((value) => value == acknowledgment)
        .timeout(timeout);
    sendCommand(cmd);
    try {
      return await response;
    } on TimeoutException {
      throw const GlassesException(GlassesFailure.udpTimeout);
    }
  }

  void _armStalledTimer() {
    _stalledTimer?.cancel();
    _stalledTimer = Timer(stalledTimeout, () {
      if (_disposed || _socket == null) return;
      // Preserve the UDP socket and periodic peer refresh across a temporary
      // RF outage. A later valid JPEG restores readiness without user restart.
      lastFailure = GlassesFailure.udpStalled;
      _ready = false;
      _statusCtl.add('stalled');
    });
  }

  void _scheduleReconnect() {
    if (_disposed ||
        !_autoReconnect ||
        _reconnectInFlight ||
        _reconnectTimer?.isActive == true) {
      return;
    }
    const delays = [1, 2, 4, 8, 16, 30];
    final delaySeconds = delays[_reconnectAttempts.clamp(0, delays.length - 1)];
    _reconnectAttempts++;
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      _reconnectTimer = null;
      unawaited(_runReconnect());
    });
  }

  Future<void> _runReconnect() async {
    if (_disposed || !_autoReconnect || _reconnectInFlight) return;
    _reconnectInFlight = true;
    var retry = false;
    try {
      final lastIp = _lastPeerAddress;
      if (lastIp == null) {
        await connect();
      } else {
        final address = parsePeerAddress(lastIp);
        try {
          if (address == null) {
            await connect();
          } else {
            await connect(espIp: address);
          }
        } catch (_) {
          await connect();
        }
      }
      if (_autoResumeStreaming && !_disposed) {
        await start(espIp: _espIp);
      }
      _reconnectAttempts = 0;
    } catch (_) {
      retry = true;
    } finally {
      _reconnectInFlight = false;
      if (retry) _scheduleReconnect();
    }
  }

  void _armPeerKeepalive() {
    _peerTimer?.cancel();
    _peerTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_disposed || _socket == null) return;
      try {
        _sendRaw([cmdPeerKeepalive]);
      } on GlassesException {
        // _sendRaw has already closed the socket and emitted failure state.
      }
    });
  }

  static bool _isNewerFrameId(int candidate, int reference) {
    final difference = (candidate - reference) & 0xffffffff;
    return difference != 0 && difference < 0x80000000;
  }

  Future<void> _rediscoverPeer() async {
    if (_disposed || !_streaming || _socket == null || _rediscoveryInFlight) {
      return;
    }
    _rediscoveryInFlight = true;
    _discovering = true;
    try {
      _socket!.broadcastEnabled = true;
      final registered = responseStream
          .firstWhere((response) => response == r'$CMD:keepalive')
          .timeout(const Duration(seconds: 3));
      var acknowledged = false;
      for (var attempt = 0; attempt < 5; attempt++) {
        final socket = _socket;
        if (socket == null || _disposed) return;
        final sent = socket.send(
          [cmdPeerKeepalive],
          InternetAddress('255.255.255.255'),
          _espPort,
        );
        if (sent != 1) break;
        try {
          await registered.timeout(const Duration(milliseconds: 600));
          acknowledged = _espIp != null;
          break;
        } on TimeoutException {
          if (attempt < 4) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
      }
      _discovering = false;
      if (!acknowledged || _espIp == null || _socket == null) {
        _scheduleDiscoveryRetry();
        return;
      }
      _peerRegistered = true;
      _lastPeerAddress = _espIp!.address;
      lastFailure = null;
      _sendRaw([cmdStreamOn]);
      _armPeerKeepalive();
      _statusCtl.add('connected');
      _armStalledTimer();
    } catch (_) {
      _discovering = false;
      _scheduleDiscoveryRetry();
    } finally {
      _rediscoveryInFlight = false;
    }
  }

  void _scheduleDiscoveryRetry() {
    if (_disposed || !_streaming || _discoveryRetryTimer?.isActive == true) {
      return;
    }
    _discoveryRetryTimer = Timer(const Duration(seconds: 4), () {
      _discoveryRetryTimer = null;
      unawaited(_rediscoverPeer());
    });
  }

  void _processPacket(Uint8List data) {
    // UDP control acknowledgements/status are plain ASCII, not video headers.
    if (data.isNotEmpty && data.first == 0x24) {
      final text = utf8.decode(data, allowMalformed: true).trim();
      _responseCtl.add(text);
      return;
    }
    if (data.length < udpHeaderLen) {
      // One-byte peer probes are transport-level ARP/registration echoes.
      return;
    }

    final header = ByteData.sublistView(data);
    final rawSequence = header.getUint32(0, Endian.little);
    final total = header.getUint32(4, Endian.little);
    final offset = header.getUint32(8, Endian.little);
    final size = header.getUint32(12, Endian.little);
    final frameId = header.getUint32(16, Endian.little);
    final frameSize = header.getUint32(20, Endian.little);
    final isParity = (rawSequence & paritySequenceFlag) != 0;
    final sequence = rawSequence & paritySequenceMask;
    if (total == 0 ||
        total > maxPacketCount ||
        frameSize < 4 ||
        frameSize > maxFrameBytes ||
        total != (frameSize + payloadBytes - 1) ~/ payloadBytes ||
        size == 0 ||
        size > payloadBytes ||
        data.length != udpHeaderLen + size) {
      return;
    }

    if (isParity) {
      final groupCount = total < fecGroupSize ? total : fecGroupSize;
      final groupStart = sequence;
      if (sequence >= groupCount ||
          offset != groupStart * payloadBytes ||
          size != payloadBytes ||
          offset >= frameSize) {
        return;
      }
    } else {
      final expectedOffset = sequence * payloadBytes;
      if (sequence >= total ||
          offset != expectedOffset ||
          offset >= frameSize ||
          size != (frameSize - offset).clamp(0, payloadBytes)) {
        return;
      }
    }

    if (_frameId == null) {
      if (_lastFrameId != null && !_isNewerFrameId(frameId, _lastFrameId!)) {
        return;
      }
      _startFrame(frameId, total, frameSize);
    } else if (frameId != _frameId) {
      if (!_isNewerFrameId(frameId, _frameId!)) return;
      _resetFrame();
      _startFrame(frameId, total, frameSize);
    } else if (total != _frameTotal || frameSize != _frameSize) {
      _resetFrame();
      return;
    }

    final payload = Uint8List.sublistView(data, udpHeaderLen);
    final packets = isParity ? _frameParity : _framePackets;
    final duplicate = packets[sequence];
    if (duplicate != null) {
      if (_sameBytes(duplicate, payload)) return;
      _resetFrame();
      return;
    }
    packets[sequence] = Uint8List.fromList(payload);
    _tryRecoverAndAssemble();
  }

  void _startFrame(int frameId, int total, int frameSize) {
    _frameId = frameId;
    _lastFrameId = frameId;
    _frameTotal = total;
    _frameSize = frameSize;
    _frameTimeoutTimer = Timer(frameTimeout, _resetFrame);
  }

  void _tryRecoverAndAssemble() {
    if (_frameId == null || _frameTotal == 0) return;

    final groupCount = _frameTotal < fecGroupSize ? _frameTotal : fecGroupSize;
    for (var groupIndex = 0; groupIndex < groupCount; groupIndex++) {
      final missing = <int>[
        for (var sequence = groupIndex;
            sequence < _frameTotal;
            sequence += fecGroupSize)
          if (!_framePackets.containsKey(sequence)) sequence,
      ];
      if (missing.length != 1) continue;
      final parity = _frameParity[groupIndex];
      if (parity == null) continue;

      final recovered = Uint8List.fromList(parity);
      for (var sequence = groupIndex;
          sequence < _frameTotal;
          sequence += fecGroupSize) {
        if (sequence == missing.single) continue;
        final part = _framePackets[sequence];
        if (part == null) continue;
        for (var index = 0; index < part.length; index++) {
          recovered[index] ^= part[index];
        }
      }
      final missingOffset = missing.single * payloadBytes;
      final expectedLength =
          (_frameSize - missingOffset).clamp(0, payloadBytes);
      _framePackets[missing.single] =
          Uint8List.fromList(recovered.sublist(0, expectedLength));
    }

    if (_framePackets.length != _frameTotal) return;
    final bytes = BytesBuilder(copy: false);
    for (var sequence = 0; sequence < _frameTotal; sequence++) {
      final part = _framePackets[sequence];
      if (part == null) return;
      bytes.add(part);
    }
    final jpeg = bytes.takeBytes();
    if (jpeg.length != _frameSize ||
        jpeg.length < 4 ||
        jpeg[0] != 0xFF ||
        jpeg[1] != 0xD8 ||
        jpeg[jpeg.length - 2] != 0xFF ||
        jpeg.last != 0xD9) {
      _resetFrame();
      return;
    }
    _resetFrame();
    unawaited(_decodeAndPublishFrame(jpeg));
  }

  Future<void> _decodeAndPublishFrame(Uint8List jpeg) async {
    final generation = _videoGeneration;
    if (_decodingGeneration == generation) return;
    _decodingGeneration = generation;
    try {
      final dimensions = await _frameDecoder(jpeg);
      if (_disposed || generation != _videoGeneration || dimensions == null) {
        return;
      }
      _ready = true;
      lastFailure = null;
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
      // Invalid images cannot establish readiness; a later frame can recover.
    } finally {
      if (_decodingGeneration == generation) _decodingGeneration = null;
    }
  }

  void _resetFrame() {
    _framePackets.clear();
    _frameParity.clear();
    _frameTotal = 0;
    _frameSize = 0;
    _frameId = null;
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
    ++_videoGeneration;
    _streaming = false;
    _ready = false;
    _readinessTimer?.cancel();
    _stalledTimer?.cancel();
    _peerTimer?.cancel();
    _discoveryRetryTimer?.cancel();
    _discoveryRetryTimer = null;
    _discovering = false;
    _rediscoveryInFlight = false;
    _resetFrame();
    _lastFrameId = null;
    _socketSub?.cancel();
    _socketSub = null;
    _socket?.close();
    _socket = null;
    _peerRegistered = false;
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
    _lastPeerAddress = _espIp?.address ?? _lastPeerAddress;
    lastFailure = failure;
    _close();
    _statusCtl.add('failed');
    if (_autoReconnect) _scheduleReconnect();
  }

  void dispose() {
    if (_disposed) return;
    _autoReconnect = false;
    _autoResumeStreaming = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _disposed = true;
    _close();
    _frameCtl.close();
    _statusCtl.close();
    _responseCtl.close();
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
    // Only parse the JPEG frame header here. Flutter's Image widget performs
    // the actual pixel decode when displaying the frame, so decoding pixels a
    // second time on a worker isolate would waste CPU on Android devices.
    return [info.width, info.height];
  } catch (_) {
    return null;
  }
}
