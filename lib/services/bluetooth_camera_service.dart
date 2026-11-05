import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/bluetooth_status.dart';
import '../models/frame_data.dart';
import '../models/spectrum_reading.dart';

/// Streams JPEG frames + UV/IR sensor telemetry from the ESP32-CAM over BLE,
/// and sends control commands back (stream on/off, single frame, flashlight).
///
/// Service contract with the firmware (must stay in sync both sides):
///  * Service UUID:  `ffe0`   TX (glasses→phone, notify): `ffe1`
///  * RX (phone→glasses, write): `ffe2`
///  * Frame protocol: JPEG chunks delimited by SOI (FFD8) / EOI (FFD9),
///    chunked into ~500-byte BLE notifications.
///  * Telemetry packets: `$UV:1234;IR:567\n` interleaved between frames.
///  * Commands (single byte writes):
///      0x01 stream on · 0x00 stream off · 0x02 single frame
///      0x03 flashlight ON · 0x04 flashlight OFF
class BluetoothCameraService {
  static const String serviceUuid = '0000ffe0-0000-1000-8000-00805f9b34fb';
  static const String txCharUuid = '0000ffe1-0000-1000-8000-00805f9b34fb';
  static const String rxCharUuid = '0000ffe2-0000-1000-8000-00805f9b34fb';

  /// Safety cap for BLE JPEG reassembly if an EOI packet is dropped.
  static const int maxFrameBytes = 512 * 1024;

  /// Auto-reconnect policy: exponential backoff 1,2,4,8,16,16 s, then give up.
  static const int maxReconnectAttempts = 6;

  // Command bytes (mirrored in firmware)
  static const int cmdStreamOn = 0x01;
  static const int cmdStreamOff = 0x00;
  static const int cmdSingleFrame = 0x02;
  static const int cmdFlashOn = 0x03;
  static const int cmdFlashOff = 0x04;

  final StreamController<BluetoothStatus> _statusCtl =
      StreamController<BluetoothStatus>.broadcast();
  Stream<BluetoothStatus> get statusStream => _statusCtl.stream;

  final StreamController<FrameData> _frameCtl =
      StreamController<FrameData>.broadcast();
  Stream<FrameData> get frameStream => _frameCtl.stream;

  final StreamController<SpectrumReading> _sensorCtl =
      StreamController<SpectrumReading>.broadcast();
  Stream<SpectrumReading> get sensorStream => _sensorCtl.stream;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _txChar;
  BluetoothCharacteristic? _rxChar;

  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
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
    _userDisconnect = false;
    _reconnectAttempts = 0;
    _statusCtl.add(BluetoothStatus.scanning);

    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      _statusCtl.add(BluetoothStatus.error);
      throw 'Bluetooth adapter is off. Turn it on and retry.';
    }

    final subscription = FlutterBluePlus.onScanResults.listen((results) async {
      for (final r in results) {
        final name = r.device.platformName.toLowerCase();
        final matchesName = name.contains('spectrulenpor') ||
            name.contains('spectralenpor') ||
            name.contains('spectraglass') ||
            name.contains('esp32');
        final advertisesService = r.advertisementData.serviceUuids
            .any((u) => u.toString().toLowerCase().contains('ffe0'));

        if (matchesName || advertisesService) {
          await FlutterBluePlus.stopScan();
          _deviceName = r.device.platformName.isNotEmpty
              ? r.device.platformName
              : 'SpectruLenPor glasses';
          await _connect(r.device);
          break;
        }
      }
    });

    await FlutterBluePlus.startScan(
      withServices: [Guid(serviceUuid)],
      timeout: scanTimeout,
    );
    await subscription.cancel();
  }

  Future<void> _connect(BluetoothDevice device) async {
    _device = device;
    _statusCtl.add(BluetoothStatus.connecting);

    await _connSub?.cancel();
    _connSub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _resetFrame();
        _statusCtl.add(BluetoothStatus.disconnected);
        // Auto-reconnect unless the user intentionally disconnected.
        if (!_userDisconnect) _scheduleReconnect();
      }
    });

    try {
      await _establishSession(device);
      _reconnectAttempts = 0;
      _reconnectPending = false;
    } catch (_) {
      _statusCtl.add(BluetoothStatus.error);
      rethrow;
    }
  }

  /// Connects, discovers the ffe0/ffe1/ffe2 service, subscribes to frame
  /// notifications and turns the stream on. Used by both first connect and
  /// every auto-reconnect attempt.
  Future<void> _establishSession(BluetoothDevice device) async {
    await device.connect(timeout: const Duration(seconds: 15));
    await device.requestMtu(517);

    final services = await device.discoverServices();
    final svc = services.firstWhere(
      (s) => s.uuid.toString().toLowerCase().contains('ffe0'),
      orElse: () => throw 'SpectruLenPor service not found on this device.',
    );
    _txChar = svc.characteristics.firstWhere(
      (c) => c.uuid.toString().toLowerCase().contains('ffe1'),
      orElse: () => throw 'TX characteristic not found.',
    );
    _rxChar = svc.characteristics.firstWhere(
      (c) => c.uuid.toString().toLowerCase().contains('ffe2'),
      orElse: () => throw 'RX characteristic not found.',
    );

    await _txChar!.setNotifyValue(true);
    await _notifySub?.cancel();
    _notifySub = _txChar!.lastValueStream.listen(_onNotification);

    await _rxChar!.write([cmdStreamOn], withoutResponse: false);
    _statusCtl.add(BluetoothStatus.connected);
  }

  void _scheduleReconnect() {
    if (_reconnectPending || _userDisconnect || _device == null) return;
    if (_reconnectAttempts >= maxReconnectAttempts) {
      debugPrint('[BLE] gave up auto-reconnect after '
          '$_reconnectAttempts attempts.');
      _statusCtl.add(BluetoothStatus.error);
      return;
    }
    _reconnectPending = true;
    _reconnectAttempts++;
    // 1, 2, 4, 8, 16, 16 s backoff steps.
    final step = (_reconnectAttempts - 1).clamp(0, 4);
    final delay = Duration(seconds: 1 << step);
    debugPrint('[BLE] auto-reconnect attempt $_reconnectAttempts/'
        '$maxReconnectAttempts in ${delay.inSeconds}s…');
    _reconnectTimer = Timer(delay, () async {
      _reconnectPending = false;
      final device = _device;
      if (device == null || _userDisconnect) return;
      try {
        _statusCtl.add(BluetoothStatus.connecting);
        await _establishSession(device);
        _reconnectAttempts = 0;
        debugPrint('[BLE] auto-reconnected to ${_deviceName ?? 'glasses'}.');
      } catch (e) {
        debugPrint('[BLE] reconnect attempt failed: $e');
        _statusCtl.add(BluetoothStatus.error);
        _scheduleReconnect(); // escalate backoff, try again
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
    if (chunk.isEmpty) return;
    final bytes = Uint8List.fromList(chunk);

    int pos = 0;
    while (pos < bytes.length) {
      if (!_capturingJpeg) {
        // --- Telemetry text packets: start with '$', end with '\n' ---
        if (bytes[pos] == 0x24 /* '$' */) {
          _lastByte = -1; // frame-stream carry cannot survive a text packet
          _textBuf.write(asciiDecode(bytes.sublist(pos)));
          final s = _textBuf.toString();
          if (s.contains('\n')) {
            for (final line in s.split('\n')) {
              final reading = SpectrumReading.tryParse(line.trim());
              if (reading != null) {
                _sensorCtl.add(reading);
              }
            }
            _textBuf.clear();
          }
          return;
        }

        // --- Scan for SOI (FFD8), honoring a 0xFF carried from the
        //     previous notification (marker split across chunks). ---
        // NB: -1 is a VALID virtual position here (pos - 1 when the FF ended
        // the previous chunk and pos == 0), so "not found" must be a
        // different sentinel — using -1 silently discarded every chunk-
        // starting straddled SOI and corrupted the frame stream.
        const int soiNotFound = -2;
        int soi = soiNotFound;
        if (_lastByte == 0xFF && bytes[pos] == 0xD8) {
          soi = pos - 1; // virtual: the FF lives at the end of the previous chunk
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
      _frameCtl.add(FrameData(
        jpegBytes: Uint8List.fromList(jpeg),
        width: 320, // ESP32-CAM firmware streams QVGA (320x240)
        height: 240,
        capturedAt: DateTime.now(),
      ));
      // Continue with the remainder (may contain the next frame's SOI
      // or trailing padding, which is dropped).
      pos = frameEndInChunk + 1;
    }
  }

  /// Minimal ASCII decode (telemetry packets are pure ASCII, plus newline).
  String asciiDecode(Uint8List bytes) {
    return String.fromCharCodes(
      bytes.where((b) => b == 0x0A || b == 0x0D || (b >= 0x20 && b < 0x7F)),
    );
  }

  // ------------------- Commands -------------------

  Future<void> _sendCmd(int byte) async {
    if (_rxChar == null) return;
    try {
      await _rxChar!.write([byte], withoutResponse: false);
    } catch (e) {
      debugPrint('[BLE] command 0x${byte.toRadixString(16)} failed: $e');
    }
  }

  /// Continuous stream (0x01).
  Future<void> resumeStream() => _sendCmd(cmdStreamOn);

  /// Stop continuous stream (battery saver) (0x00).
  Future<void> pauseStream() => _sendCmd(cmdStreamOff);

  /// Capture + send exactly one frame (0x02).
  Future<void> requestOneFrame() => _sendCmd(cmdSingleFrame);

  /// Glasses onboard flash LED (GPIO4 on AI-Thinker) — lights the sample
  /// in dim labs (0x03 / 0x04).
  Future<void> setFlashlight(bool on) =>
      _sendCmd(on ? cmdFlashOn : cmdFlashOff);

  Future<void> disconnect() async {
    _userDisconnect = true; // suppress auto-reconnect
    _reconnectTimer?.cancel();
    _reconnectPending = false;
    _reconnectAttempts = 0;
    await _connSub?.cancel();
    _connSub = null;
    await pauseStream();
    await setFlashlight(false);
    await _device?.disconnect();
    _device = null;
    _deviceName = null;
    _txChar = null;
    _rxChar = null;
    _resetFrame();
    _statusCtl.add(BluetoothStatus.disconnected);
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _connSub?.cancel();
    _notifySub?.cancel();
    _statusCtl.close();
    _frameCtl.close();
    _sensorCtl.close();
  }
}
