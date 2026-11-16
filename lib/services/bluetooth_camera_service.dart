import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/bluetooth_status.dart';
import '../models/frame_data.dart';
import '../models/glasses_setup.dart';
import '../models/spectrum_reading.dart';

/// Streams JPEG frames + UV/IR sensor telemetry from the ESP32-CAM over BLE,
/// and sends control commands back (stream on/off, single frame, flashlight).
///
/// Dual-connection architecture with the ESP-IDF firmware:
///   * BLE (ffe0/ffe1/ffe2)  — telemetry, commands, WiFi config, warnings
///   * WiFi + UDP (port 8888) — SVGA (800x600) JPEG video stream
///
/// BLE is used ONLY for initial WiFi setup. After WiFi credentials are saved
/// and the device reboots, BLE is disabled and WiFi takes over completely.
///
/// Setup flow:
///   1. Connect via BLE
///   2. Send pairing code "11111" via BLE command 0x0A
///   3. Send WiFi credentials via BLE command 0x07 ("SSID\0PASS\0")
///   4. Receive ESP MAC address + hostname via BLE notify
///   5. Send reboot command via BLE command 0x0B
///   6. ESP reboots into WiFi-only mode until saved credentials are erased
///   7. Mobile app now uses UDP video on port 8888
///
/// Service contract with the firmware:
///  * Service UUID:  `ffe0`   TX (glasses→phone, notify): `ffe1`
///  * RX (phone→glasses, write): `ffe2`
///  * Commands (single byte writes):
///      0x01 stream on · 0x00 stream off · 0x02 single frame
///      0x03 flashlight ON · 0x04 flashlight OFF
///      0x05 restart · 0x06 shutdown
///      0x07 wifi config PUT (payload: "SSID\0PASS\0")
///      0x08 wifi config GET · 0x09 connection status GET
///      0x0A ble pairing (payload: "11111") · 0x0B reboot ESP
///  * Status packets (notify): `$WIFI_CFG:ssid=...`, `$STATUS:...`,
///    `$WIFI:connected|disconnected`, `$ESP_MAC:...`, `$ESP_NAME:...`,
///    `$CMD:paired\n`, `$CMD:reboot\n`
class BluetoothCameraService {
  BluetoothCameraService();

  /// Exercises real command/notification logic without a platform or network.
  @visibleForTesting
  BluetoothCameraService.forTest({
    required Future<void> Function(List<int>) commandWriter,
    this.acknowledgmentTimeout = const Duration(seconds: 5),
    this.rebootDisconnectTimeout = const Duration(seconds: 5),
  }) : _testWriter = commandWriter {
    _sessionReady = true;
  }

  Duration acknowledgmentTimeout = const Duration(seconds: 5);
  Duration rebootDisconnectTimeout = const Duration(seconds: 5);
  Future<void> Function(List<int>)? _testWriter;
  bool _sessionReady = false;
  bool _paired = false;
  bool _configuredThisSession = false;
  bool _scanPending = false;
  bool _disposed = false;
  int _sessionGeneration = 0;
  void Function(String)? _pendingLine;
  void Function(GlassesFailure)? _pendingFailure;
  Completer<void>? _disconnectEvidence;

  bool get isConnected => _sessionReady;
  bool get isPaired => _paired;
  bool get reconnectSuppressed => _userDisconnect;

  Future<void> _cleanupComplete = Future<void>.value();

  /// Waits for asynchronous disposal in hardware-free lifecycle tests.
  @visibleForTesting
  Future<void> get debugCleanupComplete => _cleanupComplete;

  /// Bypasses scanning only; acquisition uses the production connection path.
  @visibleForTesting
  Future<void> debugConnectDevice(BluetoothDevice device) async {
    if (_disposed ||
        _scanPending ||
        _sessionReady ||
        _reconnectInFlight ||
        _releasesPending != 0) {
      throw const GlassesException(GlassesFailure.busy);
    }
    _scanPending = true;
    _userDisconnect = false;
    _reconnectTimer?.cancel();
    _reconnectPending = false;
    final generation = _sessionGeneration;
    try {
      if (!await _releaseRetiredSessions()) {
        throw const GlassesException(GlassesFailure.connectionLost);
      }
      _checkGeneration(generation);
      await _connect(device);
    } finally {
      _scanPending = false;
    }
  }

  static const int maxTextBytes = 1024;
  static const int maxSsidBytes = 32;
  static const int minPassphraseBytes = 8;
  static const int maxPassphraseBytes = 63;
  static const int pskBytes = 64;
  static const String expectedHostname = 'spectrulenpor-esp32';
  static const String pairedAck = r'$CMD:paired';
  static const String provisionedAck = r'$CMD:wifi_config_received';
  static const String rebootAck = r'$CMD:reboot';
  static const String serviceUuid = '0000ffe0-0000-1000-8000-00805f9b34fb';
  static const String txCharUuid = '0000ffe1-0000-1000-8000-00805f9b34fb';
  static const String rxCharUuid = '0000ffe2-0000-1000-8000-00805f9b34fb';

  /// Safety cap for BLE JPEG reassembly if an EOI packet is dropped.
  static const int maxFrameBytes = 512 * 1024;

  /// Auto-reconnect policy: exponential backoff 1,2,4,8,16,16 s, then give up.
  static const int maxReconnectAttempts = 6;
  static const Duration connectTimeout = Duration(seconds: 15);
  static const int requestedMtu = 517;

  // Command bytes (mirrored in firmware config.h)
  static const int cmdStreamOn = 0x01;
  static const int cmdStreamOff = 0x00;
  static const int cmdSingleFrame = 0x02;
  static const int cmdFlashOn = 0x03;
  static const int cmdFlashOff = 0x04;
  static const int cmdRestart = 0x05;
  static const int cmdShutdown = 0x06;
  static const int cmdWifiConfigPut = 0x07;
  static const int cmdWifiConfigGet = 0x08;
  static const int cmdConnectionStatus = 0x09;
  static const int cmdBlePair = 0x0A; // pairing code "11111"
  static const int cmdReboot = 0x0B; // reboot ESP after WiFi setup

  /// Pairing code required before WiFi config can be sent over BLE.
  static const String blePairingCode = '11111';

  /// ESP32-CAM MAC address discovered during BLE setup.
  String? espMacAddress;

  /// ESP32-CAM hostname discovered during BLE setup.
  String? espHostname;

  /// Whether WiFi credentials have been successfully provisioned via BLE.
  bool get isWifiConfigured => _configuredThisSession;

  final StreamController<BluetoothStatus> _statusCtl =
      StreamController<BluetoothStatus>.broadcast();
  Stream<BluetoothStatus> get statusStream => _statusCtl.stream;

  /// WiFi / connection status messages from the ESP over BLE TX.
  final StreamController<String> _statusMessageCtl =
      StreamController<String>.broadcast();
  Stream<String> get statusMessageStream => _statusMessageCtl.stream;

  final StreamController<FrameData> _frameCtl =
      StreamController<FrameData>.broadcast();
  Stream<FrameData> get frameStream => _frameCtl.stream;

  final StreamController<SpectrumReading> _sensorCtl =
      StreamController<SpectrumReading>.broadcast();
  Stream<SpectrumReading> get sensorStream => _sensorCtl.stream;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxChar;

  _BleSession? _session;
  final Set<_BleSession> _retiredSessions = {};
  int _releasesPending = 0;
  bool _reconnectInFlight = false;
  Timer? _reconnectTimer;
  bool _userDisconnect = false;
  bool _reconnectPending = false;
  int _reconnectAttempts = 0;

  // --- JPEG reassembly state (O(chunk) per notification) ---
  final BytesBuilder _jpegBuf = BytesBuilder();
  bool _capturingJpeg = false;

  /// Last byte of the byte stream seen so far while reassembling, used to
  /// detect SOI/EOI markers that straddle two BLE notifications
  /// (`…FF` | `D8…` / `…FF` | `D9…`). `-1` when not applicable.
  int _lastByte = -1;

  final StringBuffer _textBuf = StringBuffer();

  String? _deviceName;
  String? get deviceName => _deviceName;

  void init() {
    // flutter_blue_plus has no web/VM engine — degrade gracefully there.
    () async {
      try {
        await FlutterBluePlus.setLogLevel(LogLevel.warning);
      } catch (_) {
        debugPrint('[BLE] platform unavailable — BLE disabled here.');
      }
    }();
    debugPrint('[BLE] service ready');
  }

  Future<void> scanAndConnect({
    Duration scanTimeout = const Duration(seconds: 10),
  }) async {
    if (_disposed ||
        _scanPending ||
        _sessionReady ||
        _reconnectInFlight ||
        _releasesPending != 0) {
      throw const GlassesException(GlassesFailure.busy);
    }
    _scanPending = true;
    _userDisconnect = false;
    _reconnectTimer?.cancel();
    _reconnectPending = false;
    _reconnectAttempts = 0;
    _statusCtl.add(BluetoothStatus.scanning);
    final generation = _sessionGeneration;
    StreamSubscription<List<ScanResult>>? subscription;
    try {
      if (!await _releaseRetiredSessions()) {
        throw const GlassesException(GlassesFailure.connectionLost);
      }
      _checkGeneration(generation);
      if (await FlutterBluePlus.adapterState.first !=
          BluetoothAdapterState.on) {
        if (!_disposed) _statusCtl.add(BluetoothStatus.adapterOff);
        throw const GlassesException(GlassesFailure.bleUnavailable);
      }
      _checkGeneration(generation);
      final found = Completer<BluetoothDevice>();
      // Scan errors can arrive before startScan's Future has completed.
      unawaited(found.future.then<void>((_) {}, onError: (Object _) {}));
      subscription = FlutterBluePlus.onScanResults.listen(
        (results) {
          if (found.isCompleted ||
              _disposed ||
              generation != _sessionGeneration) {
            return;
          }
          for (final r in results) {
            final name = r.device.platformName.toLowerCase();
            final matchesName = name.contains('spectrulenpor') ||
                name.contains('spectralenpor') ||
                name.contains('spectraglass') ||
                name.contains('esp32');
            final advertisesService = r.advertisementData.serviceUuids.any(
              (u) => u.toString().toLowerCase().contains('ffe0'),
            );

            if (matchesName || advertisesService) {
              _deviceName = r.device.platformName.isNotEmpty
                  ? r.device.platformName
                  : null;
              found.complete(r.device);
              break;
            }
          }
        },
        onError: (Object _) {
          if (!found.isCompleted) {
            found.completeError(
              const GlassesException(GlassesFailure.bleUnavailable),
            );
          }
        },
      );
      await FlutterBluePlus.startScan(
        withServices: [Guid(serviceUuid)],
        timeout: scanTimeout,
      );
      final device = await found.future.timeout(scanTimeout);
      await FlutterBluePlus.stopScan();
      _checkGeneration(generation);
      await _connect(device);
    } on GlassesException {
      if (!_disposed && !_userDisconnect) _statusCtl.add(BluetoothStatus.error);
      rethrow;
    } catch (_) {
      if (!_disposed && !_userDisconnect) _statusCtl.add(BluetoothStatus.error);
      throw const GlassesException(GlassesFailure.bleUnavailable);
    } finally {
      // Neither release failure may skip the other or hide the scan error.
      await Future.wait([
        _attemptRelease(() async {
          await subscription?.cancel();
        }),
        _attemptRelease(FlutterBluePlus.stopScan),
      ]);
      _scanPending = false;
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    if (_disposed || _userDisconnect) {
      throw const GlassesException(GlassesFailure.connectionLost);
    }
    _device = device;
    _statusCtl.add(BluetoothStatus.connecting);

    try {
      await _establishSession(device);
      _reconnectAttempts = 0;
      _reconnectPending = false;
    } catch (_) {
      if (_device == device) {
        _device = null;
        _deviceName = null;
      }
      if (!_disposed && !_userDisconnect) _statusCtl.add(BluetoothStatus.error);
      rethrow;
    }
  }

  /// Connects, discovers the ffe0/ffe1/ffe2 service, subscribes to frame
  /// notifications. Used by both first connect and every auto-reconnect attempt.
  Future<void> _establishSession(BluetoothDevice device) async {
    final previousGeneration = _sessionGeneration;
    await _cleanupComplete;
    _checkGeneration(previousGeneration);
    if (!await _releaseRetiredSessions()) {
      throw const GlassesException(GlassesFailure.connectionLost);
    }
    _checkGeneration(previousGeneration);
    _clearSession();
    final session = _BleSession(device, _sessionGeneration);
    _session = session;
    try {
      session.connectPending = true;
      try {
        // Request MTU explicitly below, rather than the plugin's implicit MTU
        // step inside connect, so the entire acquisition has one owner.
        await device.connect(timeout: connectTimeout, mtu: null);
      } finally {
        session.connectPending = false;
      }
      _checkConnection(session);
      // connectionState replays its current value. Listen only after connect.
      session.connection = device.connectionState.listen(
        (state) {
          if (_ownsSession(session) &&
              state == BluetoothConnectionState.disconnected) {
            _onDisconnected();
          }
        },
        onError: (Object _) => _onSessionStreamError(session),
      );
      _checkConnection(session);
      await device.requestMtu(requestedMtu);
      _checkConnection(session);

      final services = await device.discoverServices();
      _checkConnection(session);
      final svc = services.firstWhere(
        (s) => s.uuid.toString().toLowerCase().contains('ffe0'),
        orElse: () =>
            throw const GlassesException(GlassesFailure.bleUnavailable),
      );
      final tx = svc.characteristics.firstWhere(
        (c) => c.uuid.toString().toLowerCase().contains('ffe1'),
        orElse: () =>
            throw const GlassesException(GlassesFailure.bleUnavailable),
      );
      final rx = svc.characteristics.firstWhere(
        (c) => c.uuid.toString().toLowerCase().contains('ffe2'),
        orElse: () =>
            throw const GlassesException(GlassesFailure.bleUnavailable),
      );
      // Unlike lastValueStream this never replays a cached ACK on reconnect.
      session.notification = tx.onValueReceived.listen(
        (bytes) {
          if (_ownsSession(session)) _onNotification(bytes);
        },
        onError: (Object _) => _onSessionStreamError(session),
      );
      _checkConnection(session);
      await tx.setNotifyValue(true);
      _checkConnection(session);
      _rxChar = rx;
      _sessionReady = true;
      _statusCtl.add(BluetoothStatus.connected);
    } catch (error) {
      if (_ownsSession(session)) _onDisconnected(observed: false);
      await _releaseSession(session);
      // Cancellation can finish before connect returns. A late successful
      // connect is still this lease's resource, never a new session's link.
      if (session.closedDuringConnect && device.isConnected) {
        await _releaseLateConnection(session);
      }
      if (error is GlassesException) rethrow;
      throw const GlassesException(GlassesFailure.bleUnavailable);
    }
  }

  void _checkGeneration(int generation) {
    if (_disposed || _userDisconnect || generation != _sessionGeneration) {
      throw const GlassesException(GlassesFailure.connectionLost);
    }
  }

  bool _ownsSession(_BleSession session) =>
      identical(_session, session) && session.generation == _sessionGeneration;

  void _checkConnection(_BleSession session) {
    _checkGeneration(session.generation);
    if (!_ownsSession(session) || !session.device.isConnected) {
      throw const GlassesException(GlassesFailure.connectionLost);
    }
  }

  void _onSessionStreamError(_BleSession session) {
    if (!_ownsSession(session)) return;
    _onDisconnected(observed: false);
    if (!_disposed && !_userDisconnect) _statusCtl.add(BluetoothStatus.error);
  }

  Future<bool> _attemptRelease(Future<void> Function() release) async {
    try {
      await release();
      return true;
    } catch (_) {
      debugPrint('[BLE] resource release failed: connectionLost');
      return false;
    }
  }

  Future<bool> _trackRelease(Future<bool> release) {
    ++_releasesPending;
    final tracked = release.whenComplete(() {
      --_releasesPending;
    });
    _cleanupComplete = Future.wait([
      _cleanupComplete,
      tracked.then<void>((_) {}),
    ]).then<void>((_) {});
    return tracked;
  }

  Future<bool> _releaseRetiredSessions() async {
    final results = await Future.wait(
      _retiredSessions.toList().map(_releaseSession),
    );
    return results.every((released) => released);
  }

  Future<bool> _releaseSession(_BleSession session) {
    final previousRelease = session.release;
    if (previousRelease != null &&
        session.connection == null &&
        session.notification == null) {
      return previousRelease;
    }
    if (previousRelease == null) {
      session.closedDuringConnect = session.connectPending;
    }
    _retiredSessions.add(session);
    final connection = session.connection;
    final notification = session.notification;
    session.connection = null;
    session.notification = null;
    // Start each release independently, even when another cancellation stalls.
    late final Future<bool> release;
    release = _trackRelease(Future.wait([
      _attemptRelease(() async {
        await connection?.cancel();
      }).then((released) {
        if (!released) session.connection ??= connection;
        return released;
      }),
      _attemptRelease(() async {
        await notification?.cancel();
      }).then((released) {
        if (!released) session.notification ??= notification;
        return released;
      }),
      // listen() may deliver a synchronous event before returning its lease.
      // A second pass cancels that late subscription, not the device again.
      previousRelease ??
          (session.deviceReleased
              ? Future<bool>.value(true)
              : _attemptRelease(() => session.device.disconnect(queue: false))
                  .then((released) {
                  session.deviceReleased = released;
                  return released;
                })),
    ]).then((results) => results.every((released) => released)))
        .then((released) {
      // A late subscription can start a newer pass before this one finishes.
      // Only the current pass may retire the lease or make it retryable.
      if (identical(session.release, release)) {
        if (released) {
          _retiredSessions.remove(session);
        } else {
          // Failed resources retain their owner for a later explicit close,
          // disposal or retry admission. Never repeat any setup/control write.
          session.release = null;
        }
      }
      return released;
    });
    session.release = release;
    return release;
  }

  Future<bool> _releaseLateConnection(_BleSession session) {
    if (session.lateRelease != null) return session.lateRelease!;
    session.release = null;
    session.deviceReleased = false;
    return session.lateRelease = _releaseSession(session);
  }

  void _clearSession() {
    ++_sessionGeneration;
    _sessionReady = false;
    _paired = false;
    _configuredThisSession = false;
    _rxChar = null;
    _textBuf.clear();
    _resetFrame();
  }

  void _onDisconnected({bool observed = true}) {
    final wasConnected = _sessionReady;
    final session = _session;
    _session = null;
    _clearSession();
    _pendingFailure?.call(GlassesFailure.connectionLost);
    if (_disconnectEvidence?.isCompleted == false) {
      if (observed && wasConnected) {
        _disconnectEvidence!.complete();
      } else {
        _disconnectEvidence!.completeError(
          const GlassesException(GlassesFailure.connectionLost),
        );
      }
    }
    if (!_disposed) _statusCtl.add(BluetoothStatus.disconnected);
    if (session != null) unawaited(_releaseSession(session));
    if (wasConnected && !_userDisconnect && !_disposed) _scheduleReconnect();
  }

  @visibleForTesting
  void debugDisconnectSession() => _onDisconnected();

  void _scheduleReconnect() {
    if (_disposed || _reconnectPending || _userDisconnect || _device == null) {
      return;
    }
    if (_reconnectAttempts >= maxReconnectAttempts) {
      debugPrint(
        '[BLE] gave up auto-reconnect after '
        '$_reconnectAttempts attempts.',
      );
      _statusCtl.add(BluetoothStatus.error);
      return;
    }
    _reconnectPending = true;
    final generation = _sessionGeneration;
    _reconnectAttempts++;
    // 1, 2, 4, 8, 16, 16 s backoff steps.
    final step = (_reconnectAttempts - 1).clamp(0, 4);
    final delay = Duration(seconds: 1 << step);
    debugPrint(
      '[BLE] auto-reconnect attempt $_reconnectAttempts/'
      '$maxReconnectAttempts in ${delay.inSeconds}s…',
    );
    _reconnectTimer = Timer(delay, () async {
      _reconnectPending = false;
      final device = _device;
      if (device == null ||
          _userDisconnect ||
          _disposed ||
          generation != _sessionGeneration) {
        return;
      }
      _reconnectInFlight = true;
      try {
        _statusCtl.add(BluetoothStatus.connecting);
        await _establishSession(device);
        _reconnectAttempts = 0;
        debugPrint('[BLE] auto-reconnected to ${_deviceName ?? 'glasses'}.');
      } catch (e) {
        if (_disposed || _userDisconnect) return;
        debugPrint('[BLE] reconnect attempt failed: $e');
        _statusCtl.add(BluetoothStatus.error);
        _scheduleReconnect(); // escalate backoff, try again
      } finally {
        _reconnectInFlight = false;
      }
    });
  }

  /// Exposed for unit testing of BLE packet reassembly.
  @visibleForTesting
  void debugFeedNotification(List<int> chunk) => _onNotification(chunk);

  void _resetFrame() {
    _jpegBuf.clear();
    _capturingJpeg = false;
    _lastByte = -1;
  }

  void _onNotification(List<int> chunk) {
    if (_disposed || chunk.isEmpty) return;
    final bytes = Uint8List.fromList(chunk);

    int pos = 0;
    while (pos < bytes.length) {
      if (!_capturingJpeg) {
        // --- Telemetry text packets: start with '$', end with '\n' ---
        if (_textBuf.isNotEmpty || bytes[pos] == 0x24 /* '$' */) {
          _lastByte = -1; // frame-stream carry cannot survive a text packet
          while (pos < bytes.length) {
            final byte = bytes[pos++];
            if (byte == 0x0A) {
              var line = utf8.decode(
                _textBuf.toString().codeUnits,
                allowMalformed: true,
              );
              _textBuf.clear();
              if (line.endsWith('\r')) {
                line = line.substring(0, line.length - 1);
              }
              _handleTextLine(line);
              break;
            }
            _textBuf.writeCharCode(byte);
            if (_textBuf.length > maxTextBytes) {
              _textBuf.clear();
              return;
            }
          }
          continue;
        }

        // --- Scan for SOI (FFD8), honoring a 0xFF carried from the
        //     previous notification (marker split across chunks). ---
        const int soiNotFound = -2;
        int soi = soiNotFound;
        if (_lastByte == 0xFF && bytes[pos] == 0xD8) {
          soi =
              pos - 1; // virtual: the FF lives at the end of the previous chunk
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
          return;
        }
        _lastByte = -1;
        _capturingJpeg = true;
        pos = (soi == pos - 1) ? pos : soi;
        if (soi == pos) {
          // SOI fully inside this chunk: seed the buffer with FF D8.
          _jpegBuf.add([0xFF, 0xD8]);
          pos = soi + 2;
        }
        continue;
      }

      // --- Capturing: append this chunk (O(chunk), no whole-buffer rescan)
      //     and look for EOI, including one straddling the previous chunk. ---
      int frameEndInChunk = -1; // inclusive index of the D9 byte
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
        if (_jpegBuf.length > maxFrameBytes) {
          debugPrint('[BLE] frame exceeded max size — resetting buffer.');
          _resetFrame();
          return;
        }
        return;
      }

      _jpegBuf.add(bytes.sublist(pos, frameEndInChunk + 1));
      final jpeg = _jpegBuf.toBytes();
      _resetFrame();
      _frameCtl.add(
        FrameData(
          jpegBytes: Uint8List.fromList(jpeg),
          width: 320, // ESP32-CAM firmware streams QVGA (320x240)
          height: 240,
          capturedAt: DateTime.now(),
        ),
      );
      // Continue with the remainder (may contain the next frame's SOI
      // or trailing padding, which is dropped).
      pos = frameEndInChunk + 1;
    }
  }

  void _handleTextLine(String line) {
    if (!line.startsWith(r'$')) return;
    _pendingLine?.call(line);
    if (line.startsWith(r'$UV:')) {
      final reading = SpectrumReading.tryParse(line);
      if (reading != null) _sensorCtl.add(reading);
    } else {
      _statusMessageCtl.add(line);
    }
  }

  /// Minimal ASCII decode (telemetry packets are pure ASCII, plus newline).
  String asciiDecode(Uint8List bytes) {
    return String.fromCharCodes(
      bytes.where((b) => b == 0x0A || b == 0x0D || (b >= 0x20 && b < 0x7F)),
    );
  }

  // ------------------- Commands -------------------

  Future<void> _write(List<int> bytes) async {
    if (!_sessionReady || (_rxChar == null && _testWriter == null)) {
      throw const GlassesException(GlassesFailure.bleUnavailable);
    }
    try {
      if (_testWriter != null) {
        await _testWriter!(bytes);
      } else {
        await _rxChar!.write(bytes, withoutResponse: false);
      }
    } catch (_) {
      throw const GlassesException(GlassesFailure.bleWriteFailed);
    }
  }

  Future<void> _confirmedWrite(
    List<int> bytes,
    bool Function(String) accepts,
  ) async {
    if (_pendingLine != null) {
      throw const GlassesException(GlassesFailure.busy);
    }
    final response = Completer<void>();
    // Install the error handler before writing: notifications/disconnects can
    // arrive before the ATT write-with-response completes.
    final result = response.future.timeout(
      acknowledgmentTimeout,
      onTimeout: () =>
          throw const GlassesException(GlassesFailure.acknowledgmentTimeout),
    );
    unawaited(result.catchError((Object _) {}));
    _textBuf.clear();
    _pendingLine = (line) {
      if (response.isCompleted) return;
      try {
        if (accepts(line)) response.complete();
      } on GlassesException catch (e) {
        response.completeError(e);
      }
    };
    _pendingFailure = (code) {
      if (!response.isCompleted) {
        response.completeError(GlassesException(code));
      }
    };
    try {
      await _write(bytes).timeout(
        acknowledgmentTimeout,
        onTimeout: () =>
            throw const GlassesException(GlassesFailure.bleWriteFailed),
      );
      await result;
    } finally {
      // Complete a failed write's waiter rather than leave a live timer.
      if (!response.isCompleted) {
        response.completeError(
          const GlassesException(GlassesFailure.bleWriteFailed),
        );
      }
      _pendingLine = null;
      _pendingFailure = null;
    }
  }

  void _requireIdle() {
    if (_pendingLine != null || _disconnectEvidence != null) {
      throw const GlassesException(GlassesFailure.busy);
    }
  }

  Future<void> _sendCmd(int byte, [String? ack]) async {
    _requireIdle();
    if (ack == null) {
      await _write([byte]);
    } else {
      await _confirmedWrite([byte], (line) => line == ack);
    }
  }

  /// Continuous stream (0x01).
  Future<void> resumeStream() => _sendCmd(cmdStreamOn, r'$CMD:stream_on');

  /// Stop continuous stream (battery saver) (0x00).
  Future<void> pauseStream() => _sendCmd(cmdStreamOff, r'$CMD:stream_off');

  /// Capture + send exactly one frame (0x02).
  Future<void> requestOneFrame() =>
      _sendCmd(cmdSingleFrame, r'$CMD:single_frame');

  /// Glasses onboard flash LED (GPIO4 on AI-Thinker) — lights the sample
  /// in dim labs (0x03 / 0x04).
  Future<void> setFlashlight(bool on) => _sendCmd(
        on ? cmdFlashOn : cmdFlashOff,
        on ? r'$CMD:flash_on' : r'$CMD:flash_off',
      );

  /// Restart the ESP32-CAM (0x05).
  Future<void> restart() async {
    _requireIdle();
    _userDisconnect = true;
    _reconnectTimer?.cancel();
    await _sendCmd(cmdRestart, r'$CMD:restart');
  }

  /// Shut down the ESP32-CAM (0x06).
  Future<void> shutdown() => _sendCmd(cmdShutdown, r'$CMD:shutdown_complete');

  static bool validCredentials(String ssid, String pass) {
    if (ssid.contains('\x00') || pass.contains('\x00')) return false;
    final ssidSize = utf8.encode(ssid).length;
    final passSize = utf8.encode(pass).length;
    if (ssidSize == 0 || ssidSize > maxSsidBytes) return false;
    return passSize == 0 ||
        (passSize >= minPassphraseBytes && passSize <= maxPassphraseBytes) ||
        (passSize == pskBytes && RegExp(r'^[0-9a-fA-F]+$').hasMatch(pass));
  }

  static bool validMac(String mac) =>
      RegExp(r'^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$').hasMatch(mac) &&
      mac != '00:00:00:00:00:00' &&
      mac.toUpperCase() != 'FF:FF:FF:FF:FF:FF' &&
      (int.parse(mac.substring(0, 2), radix: 16) & 1) == 0;

  /// Send WiFi credentials to the ESP over BLE (0x07).
  /// Payload format: "SSID\0PASS\0"
  Future<void> wifiConfigPut(String ssid, String pass) async {
    _requireIdle();
    if (!_paired) {
      throw const GlassesException(GlassesFailure.pairingRequired);
    }
    if (!validCredentials(ssid, pass)) {
      throw const GlassesException(GlassesFailure.invalidCredentials);
    }
    _configuredThisSession = false;
    final generation = _sessionGeneration;
    String? freshMac;
    String? freshHostname;
    bool acknowledged = false;
    final payload = Uint8List.fromList([
      ...utf8.encode(ssid),
      0,
      ...utf8.encode(pass),
      0,
    ]);
    await _confirmedWrite([cmdWifiConfigPut, ...payload], (line) {
      if (line == provisionedAck) acknowledged = true;
      if (line.startsWith(r'$ESP_MAC:')) {
        final mac = line.substring(r'$ESP_MAC:'.length);
        if (!validMac(mac)) {
          throw const GlassesException(GlassesFailure.invalidIdentity);
        }
        freshMac = mac.toUpperCase();
      }
      if (line.startsWith(r'$ESP_NAME:')) {
        final hostname = line.substring(r'$ESP_NAME:'.length);
        if (hostname != expectedHostname) {
          throw const GlassesException(GlassesFailure.invalidIdentity);
        }
        freshHostname = hostname;
      }
      return acknowledged && freshMac != null && freshHostname != null;
    });
    if (!_sessionReady || generation != _sessionGeneration) {
      throw const GlassesException(GlassesFailure.connectionLost);
    }
    espMacAddress = freshMac;
    espHostname = freshHostname;
    _configuredThisSession = true;
  }

  /// Send pairing code to the ESP over BLE (0x0A).
  /// Payload format: "11111"
  Future<void> blePair(String pairingCode) async {
    _requireIdle();
    _paired = false;
    final generation = _sessionGeneration;
    if (pairingCode != blePairingCode) {
      throw const GlassesException(GlassesFailure.pairingRequired);
    }
    final payload = Uint8List.fromList(utf8.encode(pairingCode));
    await _confirmedWrite([
      cmdBlePair,
      ...payload,
    ], (line) => line == pairedAck);
    _paired = _sessionReady && generation == _sessionGeneration;
    if (!_paired) {
      throw const GlassesException(GlassesFailure.connectionLost);
    }
  }

  /// Reboot the ESP32-CAM (0x0B).
  Future<void> reboot() async {
    _requireIdle();
    if (!_paired || !_configuredThisSession) {
      throw const GlassesException(GlassesFailure.pairingRequired);
    }
    _userDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectPending = false;
    final disconnectEvidence = Completer<void>();
    _disconnectEvidence = disconnectEvidence;
    unawaited(disconnectEvidence.future.catchError((Object _) {}));
    try {
      await _confirmedWrite([cmdReboot], (line) => line == rebootAck);
      await disconnectEvidence.future.timeout(
        rebootDisconnectTimeout,
        onTimeout: () =>
            throw const GlassesException(GlassesFailure.rebootTimeout),
      );
    } finally {
      if (!disconnectEvidence.isCompleted) disconnectEvidence.complete();
      _disconnectEvidence = null;
      // A missing ACK may still mean the device rebooted. Never auto-reconnect
      // or automatically repeat provisioning to recover this uncertainty.
    }
  }

  /// Request current WiFi config from the ESP (0x08).
  Future<void> wifiConfigGet() => _sendCmd(cmdWifiConfigGet);

  /// Request connection + WiFi status from the ESP (0x09).
  Future<void> connectionStatusGet() => _sendCmd(cmdConnectionStatus);

  Future<void> disconnect() async {
    _userDisconnect = true; // suppress auto-reconnect
    _reconnectTimer?.cancel();
    _reconnectPending = false;
    _reconnectAttempts = 0;
    final rx =
        _sessionReady && _pendingLine == null && _disconnectEvidence == null
            ? _rxChar
            : null;
    final testWriter =
        _sessionReady && _pendingLine == null && _disconnectEvidence == null
            ? _testWriter
            : null;
    _device = null;
    _deviceName = null;
    // An app-requested close is not evidence that the reboot happened.
    _onDisconnected(observed: false);
    final closingGeneration = _sessionGeneration;
    // Best-effort legacy stream/flash-off writes must not delay link release,
    // resurrect authorization or use a newer session's characteristic.
    if (rx != null || testWriter != null) {
      _trackRelease(_attemptRelease(() async {
        for (final command in [cmdStreamOff, cmdFlashOff]) {
          if (_disposed || closingGeneration != _sessionGeneration) break;
          try {
            if (testWriter != null) {
              await testWriter([command]).timeout(acknowledgmentTimeout);
            } else {
              await rx!.write([command],
                  withoutResponse: false).timeout(acknowledgmentTimeout);
            }
          } catch (_) {
            // Continue best-effort shutdown; physical release runs separately.
          }
        }
      }));
    }
    final released = await _releaseRetiredSessions();
    await _cleanupComplete;
    if (!released) throw const GlassesException(GlassesFailure.connectionLost);
  }

  void dispose() {
    if (_disposed) {
      unawaited(_releaseRetiredSessions());
      return;
    }
    _disposed = true;
    _userDisconnect = true;
    _device = null;
    _deviceName = null;
    _reconnectTimer?.cancel();
    _reconnectPending = false;
    _onDisconnected(observed: false);
    unawaited(_releaseRetiredSessions());
    _trackRelease(Future.wait([
      _attemptRelease(_statusCtl.close),
      _attemptRelease(_frameCtl.close),
      _attemptRelease(_sensorCtl.close),
      _attemptRelease(_statusMessageCtl.close),
    ]).then((results) => results.every((released) => released)));
  }
}

/// Resources belong to one acquisition, including a connect that returns late.
class _BleSession {
  final BluetoothDevice device;
  final int generation;
  StreamSubscription<BluetoothConnectionState>? connection;
  StreamSubscription<List<int>>? notification;
  bool connectPending = false;
  bool closedDuringConnect = false;
  bool deviceReleased = false;
  Future<bool>? release;
  Future<bool>? lateRelease;

  _BleSession(this.device, this.generation);
}
