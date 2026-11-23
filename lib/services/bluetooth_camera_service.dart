import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/bluetooth_status.dart';
import '../models/frame_data.dart';
import '../models/glasses_setup.dart';
import '../models/spectrum_reading.dart';
import 'ble_protocol.dart';
import 'ble_session_manager.dart';

/// BLE commissioning and basic setup controls for the ESP32-CAM.
/// All camera frames and post-provisioning runtime commands use WiFi UDP.
///
/// Dual-connection architecture with the ESP-IDF firmware:
///   * BLE (ffe0/ffe1/ffe2)  — pairing, WiFi provisioning, status, flash, reboot
///   * WiFi + UDP (port 8888) — all camera JPEG frames and runtime commands
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
class BluetoothCameraService {
  // -----------------------------------------------------------------------
  // Protocol constants (re-exported from ble_protocol.dart so the public
  // API surface stays on this class).
  // -----------------------------------------------------------------------
  static const int cmdStreamOff = BleProtocol.cmdStreamOff;
  static const int cmdStreamOn = BleProtocol.cmdStreamOn;
  static const int cmdSingleFrame = BleProtocol.cmdSingleFrame;
  static const int cmdFlashOn = BleProtocol.cmdFlashOn;
  static const int cmdFlashOff = BleProtocol.cmdFlashOff;
  static const int cmdRestart = BleProtocol.cmdRestart;
  static const int cmdShutdown = BleProtocol.cmdShutdown;
  static const int cmdWifiConfigPut = BleProtocol.cmdWifiConfigPut;
  static const int cmdWifiConfigGet = BleProtocol.cmdWifiConfigGet;
  static const int cmdConnectionStatus = BleProtocol.cmdConnectionStatus;
  static const int cmdBlePair = BleProtocol.cmdBlePair;
  static const int cmdReboot = BleProtocol.cmdReboot;

  static const String blePairingCode = BleProtocol.blePairingCode;
  static const String expectedHostname = BleProtocol.expectedHostname;
  static const String pairedAck = BleProtocol.pairedAck;
  static const String provisionedAck = BleProtocol.provisionedAck;
  static const String rebootAck = BleProtocol.rebootAck;

  /// Validate the SSID and WPA2/WPA3 passphrase accepted by ESP firmware.
  static bool validCredentials(String ssid, String passphrase) {
    if (ssid.codeUnits.contains(0) || passphrase.codeUnits.contains(0)) {
      return false;
    }
    final ssidLength = utf8.encode(ssid).length;
    final passwordLength = utf8.encode(passphrase).length;
    if (ssidLength < 1 || ssidLength > BleProtocol.maxSsidBytes) {
      return false;
    }
    if (passwordLength == 0) return true;
    if (passwordLength >= BleProtocol.minPassphraseBytes &&
        passwordLength <= BleProtocol.maxPassphraseBytes) {
      return true;
    }
    if (passwordLength == BleProtocol.pskBytes) {
      return RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(passphrase);
    }
    return false;
  }

  static const String serviceUuid = BleProtocol.serviceUuid;
  static const String txCharUuid = BleProtocol.txCharUuid;
  static const String rxCharUuid = BleProtocol.rxCharUuid;

  // -----------------------------------------------------------------------
  // Constructors
  // -----------------------------------------------------------------------

  BluetoothCameraService() {
    _sessionManager = BleSessionManager(
      onSessionEstablished: _onSessionEstablished,
      onSessionLost: _onSessionLost,
      onNotification: _onNotificationFromSession,
      onReconnectFailed: _onReconnectFailed,
    );
  }

  /// Exercises real command/notification logic without a platform or network.
  @visibleForTesting
  BluetoothCameraService.forTest({
    required Future<void> Function(List<int>) commandWriter,
    this.acknowledgmentTimeout = const Duration(seconds: 5),
    this.rebootDisconnectTimeout = const Duration(seconds: 5),
  }) : _testWriter = commandWriter {
    _sessionManager = BleSessionManager(
      onSessionEstablished: () async {},
      onSessionLost: ({required bool observed}) {},
      onNotification: (_) {},
    );
    _sessionReady = true;
  }

  // -----------------------------------------------------------------------
  // Public configuration
  // -----------------------------------------------------------------------

  Duration acknowledgmentTimeout = const Duration(seconds: 5);
  Duration rebootDisconnectTimeout = const Duration(seconds: 5);

  Future<void> Function(List<int>)? _testWriter;

  // -----------------------------------------------------------------------
  // Public state getters
  // -----------------------------------------------------------------------

  bool get isConnected => _sessionReady;
  bool get isPaired => _paired;
  bool get isWifiConfigured => _configuredThisSession;
  bool get reconnectSuppressed => _sessionManager.reconnectSuppressed;

  String? _deviceName;
  String? get deviceName => _deviceName;

  String? espMacAddress;
  String? espHostname;

  // -----------------------------------------------------------------------
  // Streams
  // -----------------------------------------------------------------------

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

  // -----------------------------------------------------------------------
  // Internal state
  // -----------------------------------------------------------------------

  late final BleSessionManager _sessionManager;

  bool _sessionReady = false;
  bool _paired = false;
  bool _configuredThisSession = false;
  bool _scanPending = false;
  bool _disposed = false;

  int _sessionGeneration = 0;
  void Function(String)? _pendingLine;
  void Function(GlassesFailure)? _pendingFailure;
  Completer<void>? _disconnectEvidence;
  Completer<void>? _pendingIdentity;
  String? _freshProvisioningMac;
  String? _freshProvisioningHostname;
  bool _rebootPending = false;

  Future<void> _cleanupComplete = Future<void>.value();

  /// Waits for asynchronous disposal in hardware-free lifecycle tests.
  @visibleForTesting
  Future<void> get debugCleanupComplete => _cleanupComplete;

  // -----------------------------------------------------------------------
  // Init / scan / connect
  // -----------------------------------------------------------------------

  void init() {
    // flutter_blue_plus has no web/VM engine — degrade gracefully there.
    unawaited(
      () async {
        try {
          await FlutterBluePlus.setLogLevel(LogLevel.warning);
        } catch (_) {
          debugPrint('[BLE] platform unavailable — BLE disabled here.');
        }
      }(),
    );
    debugPrint('[BLE] service ready');
  }

  Future<void> scanAndConnect({
    Duration scanTimeout = const Duration(seconds: 10),
  }) async {
    if (_disposed ||
        _scanPending ||
        _sessionReady ||
        _sessionManager.releasesPending != 0) {
      throw const GlassesException(GlassesFailure.busy);
    }
    _scanPending = true;
    _userDisconnect = false;
    _sessionManager.prepareForUserConnect();
    _statusCtl.add(BluetoothStatus.scanning);
    final generation = _sessionGeneration;
    StreamSubscription<List<ScanResult>>? subscription;
    try {
      if (!await _sessionManager.releaseRetiredSessions()) {
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
              (u) => u.str128 == serviceUuid,
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
      await Future.wait([
        _attemptRelease(() async {
          await subscription?.cancel();
        }),
        _attemptRelease(FlutterBluePlus.stopScan),
      ]);
      _scanPending = false;
    }
  }

  /// Bypasses scanning only; acquisition uses the production connection path.
  @visibleForTesting
  Future<void> debugConnectDevice(BluetoothDevice device) async {
    if (_disposed ||
        _scanPending ||
        _sessionReady ||
        _sessionManager.releasesPending != 0) {
      throw const GlassesException(GlassesFailure.busy);
    }
    _scanPending = true;
    _userDisconnect = false;
    _sessionManager.prepareForUserConnect();
    final generation = _sessionGeneration;
    try {
      if (!await _sessionManager.releaseRetiredSessions()) {
        throw const GlassesException(GlassesFailure.connectionLost);
      }
      _checkGeneration(generation);
      await _sessionManager.connect(device);
    } finally {
      _scanPending = false;
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    if (_disposed || _userDisconnect) {
      throw const GlassesException(GlassesFailure.connectionLost);
    }
    _statusCtl.add(BluetoothStatus.connecting);

    try {
      await _sessionManager.connect(device);
    } catch (_) {
      if (!_disposed && !_userDisconnect) _statusCtl.add(BluetoothStatus.error);
      rethrow;
    }
  }

  // -----------------------------------------------------------------------
  // Session lifecycle callbacks (wired into BleSessionManager)
  // -----------------------------------------------------------------------

  /// Called by the session manager when a new BLE session is fully
  /// established (connected, MTU negotiated, services discovered, notifications
  /// subscribed). Marks the session ready.
  Future<void> _onSessionEstablished() async {
    _sessionReady = true;
    _statusCtl.add(BluetoothStatus.connected);
  }

  /// Called by the session manager when the current session is lost.
  void _onSessionLost({required bool observed}) {
    _onDisconnected(observed: observed);
  }

  void _onReconnectFailed() {
    if (!_disposed && !_userDisconnect) {
      _statusCtl.add(BluetoothStatus.error);
    }
  }

  /// Called by the session manager when a BLE notification payload arrives.
  /// Only ASCII commissioning/status messages are accepted; binary payloads are discarded.
  void _onNotificationFromSession(List<int> bytes) {
    if (_disposed || bytes.isEmpty) return;

    // Notifications may split an ASCII response at any byte boundary.
    // Accept continuation chunks while a line is already buffered.
    if (bytes.first == 0x24 || _textBuf.isNotEmpty) {
      final text = asciiDecode(Uint8List.fromList(bytes));
      _textBuf.write(text);
      while (true) {
        final buffered = _textBuf.toString();
        final newline = buffered.indexOf('\n');
        if (newline < 0) break;
        final line = buffered
            .substring(0, newline)
            .replaceAll(String.fromCharCode(13), '');
        _textBuf
          ..clear()
          ..write(buffered.substring(newline + 1));
        _handleTextLine(line);
      }
      if (_textBuf.length > BleProtocol.maxTextBytes) {
        _textBuf.clear();
      }
      return;
    }

    // Never accept or decode image payloads from BLE. Older firmware used
    // this path for JPEG chunks; runtime camera traffic now belongs to UDP.
    debugPrint(
      '[BLE] ignored \${bytes.length} non-text bytes; video requires UDP.',
    );
  }

  // -----------------------------------------------------------------------
  // Disconnect / dispose / reconnect
  // -----------------------------------------------------------------------

  bool _userDisconnect = false;

  Future<void> disconnect({bool user = true}) async {
    if (_disconnectEvidence?.isCompleted == false) {
      _disconnectEvidence!.completeError(
        const GlassesException(GlassesFailure.connectionLost),
      );
    }
    final rebooting = _rebootPending;
    _rebootPending = false;
    _userDisconnect = user;

    if (!_sessionManager.hasSession) {
      await _sessionManager.disconnect(user: user);
      _clearSession();
      _statusCtl.add(BluetoothStatus.disconnected);
      return;
    }

    // BLE is setup-only. Switch off the test flashlight unless a reboot has
    // already been submitted; stream controls and video remain UDP-only.
    if (!rebooting) {
      unawaited(_write([BleProtocol.cmdFlashOff]).catchError((Object _) {}));
    }

    await _sessionManager.disconnect(user: user);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_disconnectEvidence?.isCompleted == false) {
      _disconnectEvidence!.completeError(
        const GlassesException(GlassesFailure.connectionLost),
      );
    }
    _rebootPending = false;
    _userDisconnect = true;
    _sessionReady = false;
    _clearSession();
    _sessionManager.dispose();
    _cleanupComplete = _sessionManager.cleanupComplete;
  }

  @visibleForTesting
  void debugDisconnectSession() {
    _onDisconnected(observed: true);
    _sessionManager.debugDisconnectCurrentSession();
  }

  @visibleForTesting
  void debugFeedNotification(List<int> chunk) =>
      _onNotificationFromSession(chunk);

  // -----------------------------------------------------------------------
  // Text telemetry handling
  // -----------------------------------------------------------------------

  void _handleTextLine(String line) {
    if (!line.startsWith(r'$')) return;
    _pendingLine?.call(line);
    if (line.startsWith(r'$ESP_MAC:')) {
      espMacAddress = line.substring(r'$ESP_MAC:'.length).trim();
      _freshProvisioningMac = espMacAddress;
      if (!_validEspMac(_freshProvisioningMac!)) {
        if (_pendingIdentity?.isCompleted == false) {
          _pendingIdentity!.completeError(
            const GlassesException(GlassesFailure.invalidIdentity),
          );
        }
      }
    } else if (line.startsWith(r'$ESP_NAME:')) {
      espHostname = line.substring(r'$ESP_NAME:'.length).trim();
      _freshProvisioningHostname = espHostname;
      if (_freshProvisioningHostname != expectedHostname) {
        if (_pendingIdentity?.isCompleted == false) {
          _pendingIdentity!.completeError(
            const GlassesException(GlassesFailure.invalidIdentity),
          );
        }
      }
    }
    if (_freshProvisioningMac != null &&
        _freshProvisioningHostname != null &&
        _pendingIdentity?.isCompleted == false) {
      _pendingIdentity!.complete();
    }
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

  // -----------------------------------------------------------------------
  // Commands
  // -----------------------------------------------------------------------

  Future<void> _write(List<int> bytes) async {
    if (!_sessionReady ||
        (_sessionManager.rxChar == null && _testWriter == null)) {
      throw const GlassesException(GlassesFailure.bleUnavailable);
    }
    try {
      if (_testWriter != null) {
        await _testWriter!(bytes);
      } else {
        await _sessionManager.rxChar!.write(bytes, withoutResponse: false);
      }
    } catch (_) {
      throw const GlassesException(GlassesFailure.bleWriteFailed);
    }
  }

  Future<void> _confirmedWrite(
    List<int> bytes,
    bool Function(String) accepts,
  ) async {
    await _confirmedLineWrite(bytes, accepts);
  }

  Future<String> _confirmedLineWrite(
    List<int> bytes,
    bool Function(String) accepts,
  ) async {
    if (_pendingLine != null) {
      throw const GlassesException(GlassesFailure.busy);
    }
    final response = Completer<String>();
    final result = response.future.timeout(
      acknowledgmentTimeout,
      onTimeout: () =>
          throw const GlassesException(GlassesFailure.acknowledgmentTimeout),
    );
    unawaited(result.catchError((Object _) => ''));
    _textBuf.clear();
    _pendingLine = (line) {
      if (response.isCompleted) return;
      try {
        if (accepts(line)) response.complete(line);
      } on GlassesException catch (error) {
        response.completeError(error);
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
      return await result;
    } finally {
      if (!response.isCompleted) {
        response.completeError(
          const GlassesException(GlassesFailure.bleWriteFailed),
        );
      }
      _pendingLine = null;
      _pendingFailure = null;
    }
  }

  final StringBuffer _textBuf = StringBuffer();

  // -----------------------------------------------------------------------
  // Public setup commands
  // -----------------------------------------------------------------------

  Future<void> blePair(String code) async {
    if (_rebootPending) {
      throw const GlassesException(GlassesFailure.busy);
    }
    if (!_sessionReady) {
      throw const GlassesException(GlassesFailure.bleUnavailable);
    }
    final payload = utf8.encode(code);
    await _confirmedWrite(
      [cmdBlePair, ...payload],
      (line) => line == pairedAck,
    );
    _paired = true;
  }

  Future<void> wifiConfigPut(String ssid, String pass) async {
    if (_rebootPending) {
      throw const GlassesException(GlassesFailure.busy);
    }
    if (!_sessionReady) {
      throw const GlassesException(GlassesFailure.bleUnavailable);
    }
    if (!_paired) {
      throw const GlassesException(GlassesFailure.pairingRequired);
    }
    if (!validCredentials(ssid, pass)) {
      throw const GlassesException(GlassesFailure.invalidCredentials);
    }
    final ssidBytes = utf8.encode(ssid);
    final passBytes = utf8.encode(pass);
    final payload = <int>[...ssidBytes, 0, ...passBytes, 0];
    _freshProvisioningMac = null;
    _freshProvisioningHostname = null;
    final identity = Completer<void>();
    unawaited(identity.future.catchError((Object _) {}));
    _pendingIdentity = identity;
    try {
      await _confirmedWrite(
        [cmdWifiConfigPut, ...payload],
        (line) => line == provisionedAck,
      );
      if (_freshProvisioningMac == null || _freshProvisioningHostname == null) {
        await identity.future.timeout(
          acknowledgmentTimeout,
          onTimeout: () => throw const GlassesException(
            GlassesFailure.acknowledgmentTimeout,
          ),
        );
      }
      if (!_sessionReady) {
        throw const GlassesException(GlassesFailure.connectionLost);
      }
      if (_freshProvisioningMac == null ||
          !_validEspMac(_freshProvisioningMac!) ||
          _freshProvisioningHostname != expectedHostname) {
        throw const GlassesException(GlassesFailure.invalidIdentity);
      }
      _configuredThisSession = true;
    } finally {
      _pendingIdentity = null;
    }
  }

  static bool _validEspMac(String value) {
    final match =
        RegExp(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$').hasMatch(value);
    if (!match) return false;
    final octets = value.split(':').map((part) => int.parse(part, radix: 16));
    final bytes = octets.toList(growable: false);
    return bytes.any((byte) => byte != 0) &&
        bytes.every((byte) => byte != 255) &&
        (bytes.first & 1) == 0;
  }

  Future<void> reboot() async {
    if (!_sessionReady) {
      throw const GlassesException(GlassesFailure.bleUnavailable);
    }
    if (_disconnectEvidence != null) {
      throw const GlassesException(GlassesFailure.busy);
    }

    // Once reboot has been submitted, a lost ACK/disconnect is ambiguous:
    // suppress auto-reconnect so setup cannot silently fall back to BLE.
    _userDisconnect = true;
    _rebootPending = true;
    _sessionManager.suppressReconnect();
    final disconnectEvidence = Completer<void>();
    _disconnectEvidence = disconnectEvidence;
    unawaited(disconnectEvidence.future.catchError((Object _) {}));
    try {
      await _confirmedWrite(
        [cmdReboot],
        (line) => line == rebootAck,
      );
      await disconnectEvidence.future.timeout(
        rebootDisconnectTimeout,
        onTimeout: () => throw const GlassesException(
          GlassesFailure.rebootTimeout,
        ),
      );
    } finally {
      _disconnectEvidence = null;
      _rebootPending = false;
    }
  }

  Future<String> wifiConfigGet() async {
    if (!_sessionReady) {
      throw const GlassesException(GlassesFailure.bleUnavailable);
    }
    return _confirmedLineWrite(
      [cmdWifiConfigGet],
      (line) => line.startsWith(r'$WIFI_CFG:'),
    );
  }

  Future<String> connectionStatusGet() async {
    if (!_sessionReady) {
      throw const GlassesException(GlassesFailure.bleUnavailable);
    }
    return _confirmedLineWrite(
      [cmdConnectionStatus],
      (line) => line.startsWith(r'$STATUS:'),
    );
  }

  /// BLE is kept for basic local controls during commissioning only.
  Future<void> setFlashlight(bool enabled) async {
    if (!_sessionReady) {
      throw const GlassesException(GlassesFailure.bleUnavailable);
    }
    final command = enabled ? BleProtocol.cmdFlashOn : BleProtocol.cmdFlashOff;
    final acknowledgment = enabled ? r'$CMD:flash_on' : r'$CMD:flash_off';
    await _confirmedWrite(
      [command],
      (line) => line == acknowledgment,
    );
  }

  Future<void> shutdown() async {
    if (!_sessionReady) {
      throw const GlassesException(GlassesFailure.bleUnavailable);
    }
    await _confirmedWrite(
      [cmdShutdown],
      (line) => line == r'$CMD:shutdown_complete',
    );
  }

  Future<void> restart() async {
    if (!_sessionReady) {
      throw const GlassesException(GlassesFailure.bleUnavailable);
    }
    await _confirmedWrite(
      [cmdRestart],
      (line) => line == r'$CMD:restart',
    );
  }

  /// Compatibility guard for callers still on the former BLE camera API.
  /// The camera transport is UDP-only; this method never writes a BLE command.
  Future<void> pauseStream() async {
    if (!_sessionReady) {
      throw const GlassesException(GlassesFailure.bleUnavailable);
    }
    if (_rebootPending || _pendingLine != null) {
      throw const GlassesException(GlassesFailure.busy);
    }
    throw const GlassesException(GlassesFailure.unsupportedControl);
  }

  // -----------------------------------------------------------------------
  // Internal helpers
  // -----------------------------------------------------------------------

  void _checkGeneration(int generation) {
    if (_disposed || _userDisconnect || generation != _sessionGeneration) {
      throw const GlassesException(GlassesFailure.connectionLost);
    }
  }

  void _clearSession() {
    _sessionGeneration++;
    _sessionReady = false;
    _paired = false;
    _configuredThisSession = false;
    _textBuf.clear();
  }

  void _onDisconnected({bool observed = true}) {
    final wasConnected = _sessionReady;
    _sessionReady = false;
    _paired = false;
    _configuredThisSession = false;
    _pendingFailure?.call(GlassesFailure.connectionLost);
    if (_pendingIdentity != null) {
      espMacAddress = null;
      espHostname = null;
      _freshProvisioningMac = null;
      _freshProvisioningHostname = null;
    }
    if (_pendingIdentity?.isCompleted == false) {
      _pendingIdentity!.completeError(
        const GlassesException(GlassesFailure.connectionLost),
      );
    }
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
    _sessionGeneration++;
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
}
