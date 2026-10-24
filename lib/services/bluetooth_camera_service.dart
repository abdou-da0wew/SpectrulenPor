import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

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

  final BytesBuilder _jpegBuf = BytesBuilder();
  bool _capturingJpeg = false;
  final StringBuffer _textBuf = StringBuffer();

  String? _deviceName;

  void init() {
    FlutterBluePlus.setLogLevel(LogLevel.warning);
  }

  Future<void> scanAndConnect({
    Duration scanTimeout = const Duration(seconds: 10),
  }) async {
    _statusCtl.add(BluetoothStatus.scanning);

    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      _statusCtl.add(BluetoothStatus.error);
      throw 'Bluetooth adapter is off. Turn it on and retry.';
    }

    final subscription = FlutterBluePlus.onScanResults.listen((results) async {
      for (final r in results) {
        final name = r.device.platformName.toLowerCase();
        final matchesName = name.contains('spectralenpor') ||
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

    try {
      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _statusCtl.add(BluetoothStatus.disconnected);
        }
      });

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
      _txChar!.lastValueStream.listen(_onNotification);

      await _rxChar!.write([cmdStreamOn], withoutResponse: false);
      _statusCtl.add(BluetoothStatus.connected);
    } catch (e) {
      _statusCtl.add(BluetoothStatus.error);
      rethrow;
    }
  }

  void _onNotification(List<int> chunk) {
    if (chunk.isEmpty) return;
    final bytes = Uint8List.fromList(chunk);

    // --- Telemetry text packets: start with '$', end with '\n' ---
    if (!_capturingJpeg && bytes[0] == 0x24 /* '$' */) {
      _textBuf.write(asciiDecode(bytes));
      final s = _textBuf.toString();
      if (s.contains('\n')) {
        for (final line in s.split('\n')) {
          final reading = SpectrumReading.tryParse(line.trim());
          if (reading != null) _sensorCtl.add(reading);
        }
        _textBuf.clear();
      }
      return;
    }

    // --- JPEG reassembly ---
    int i = 0;
    while (i < bytes.length - 1) {
      if (!_capturingJpeg && bytes[i] == 0xFF && bytes[i + 1] == 0xD8) {
        _jpegBuf.clear();
        _jpegBuf.add(bytes.sublist(i));
        _capturingJpeg = true;
        break;
      }
      i++;
    }

    if (_capturingJpeg && i > 0) {
      _jpegBuf.add(bytes.sublist(i));
    }

    if (_capturingJpeg) {
      final built = _jpegBuf.toBytes();
      if (built.length >= 2 &&
          built[built.length - 2] == 0xFF &&
          built[built.length - 1] == 0xD9) {
        _frameCtl.add(FrameData(
          jpegBytes: Uint8List.fromList(built),
          width: 640,
          height: 480,
          capturedAt: DateTime.now(),
        ));
        _jpegBuf.clear();
        _capturingJpeg = false;
      }
    }
  }

  /// Minimal ASCII decode (telemetry packets are pure ASCII).
  String asciiDecode(Uint8List bytes) {
    return String.fromCharCodes(bytes.where((b) => b >= 0x20 && b < 0x7F));
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
    await pauseStream();
    await setFlashlight(false);
    await _device?.disconnect();
    _device = null;
    _txChar = null;
    _rxChar = null;
    _statusCtl.add(BluetoothStatus.disconnected);
  }

  void dispose() {
    _statusCtl.close();
    _frameCtl.close();
    _sensorCtl.close();
  }
}
