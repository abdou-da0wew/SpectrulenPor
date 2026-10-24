import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/frame_data.dart';

/// Streams JPEG frames from a paired ESP32-CAM over Bluetooth Low Energy.
///
/// Service contract with the ESP32-CAM firmware:
///  * Service UUID:        `0000ffe0-0000-1000-8000-00805f9b34fb` (Nordic UART-like)
///  * TX characteristic:    `0000ffe1-0000-1000-8000-00805f9b34fb` (glasses -> phone notifications)
///  * RX characteristic:   `0000ffe2-0000-1000-8000-00805f9b34fb` (phone -> glasses commands)
///  * Frame protocol:
///      - Each JPEG is wrapped: `[0xFF 0xD8 ... jpeg payload ... 0xFF 0xD9]`
///      - The ESP32-CAM chunks the JPEG into ~180-byte BLE packets.
///      - We buffer until we see the JPEG end marker (0xFFD9) then emit FrameData.
///  * Capture trigger:
///      - Phone writes byte `0x01` to RX to ask for 1 frame.
///      - Phone writes byte `0x00` to RX to stop continuous stream.
///
/// For full BLE MTU negotiation, call `requestMtu(517)` after connect.
class BluetoothCameraService {
  static const String serviceUuid = '0000ffe0-0000-1000-8000-00805f9b34fb';
  static const String txCharUuid  = '0000ffe1-0000-1000-8000-00805f9b34fb';
  static const String rxCharUuid  = '0000ffe2-0000-1000-8000-00805f9b34fb';

  // Stream controllers
  final StreamController<BluetoothStatus> _statusCtl =
      StreamController<BluetoothStatus>.broadcast();
  Stream<BluetoothStatus> get statusStream => _statusCtl.stream;

  final StreamController<FrameData> _frameCtl =
      StreamController<FrameData>.broadcast();
  Stream<FrameData> get frameStream => _frameCtl.stream;

  // Active state
  BluetoothDevice? _device;
  BluetoothCharacteristic? _txChar;
  BluetoothCharacteristic? _rxChar;

  // JPEG reassembly buffer
  final BytesBuilder _jpegBuf = BytesBuilder();
  bool _capturingJpeg = false;

  /// Called by main() so Flutter Blue can warm up.
  void init() {
    FlutterBluePlus.setLogLevel(LogLevel.warning);
  }

  Future<void> scanAndConnect({
    Duration scanTimeout = const Duration(seconds: 10),
  }) async {
    _statusCtl.add(BluetoothStatus.scanning);

    // Wait for adapter to be on
    if (await FlutterBluePlus.adapterState.first !=
        BluetoothAdapterState.on) {
      _statusCtl.add(BluetoothStatus.error);
      throw 'Bluetooth adapter is off. Turn it on and retry.';
    }

    // Start scanning
    final subscription = FlutterBluePlus.onScanResults.listen(
      (results) async {
        for (final r in results) {
          // Heuristic: connect to the first device that advertises our service
          // OR a device name that matches the glasses.
          final matchesName = (r.device.platformName).toLowerCase().contains(
                  'spectraglass') ||
              (r.device.platformName).toLowerCase().contains('esp32');
          final advertisesService = r.advertisementData.serviceUuids
              .any((u) => u.toString().toLowerCase().contains('ffe0'));

          if (matchesName || advertisesService) {
            await FlutterBluePlus.stopScan();
            await _connect(r.device);
            break;
          }
        }
      },
    );

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
      await device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _statusCtl.add(BluetoothStatus.disconnected);
        }
      });

      await device.connect(timeout: const Duration(seconds: 15));
      await device.requestMtu(517); // max BLE MTU, faster frame chunks

      // Discover services
      final services = await device.discoverServices();
      final svc = services.firstWhere(
        (s) => s.uuid.toString().toLowerCase().contains('ffe0'),
        orElse: () => throw 'ESP32-CAM service not found on this device.',
      );

      _txChar = svc.characteristics.firstWhere(
        (c) => c.uuid.toString().toLowerCase().contains('ffe1'),
        orElse: () => throw 'TX characteristic not found.',
      );
      _rxChar = svc.characteristics.firstWhere(
        (c) => c.uuid.toString().toLowerCase().contains('ffe2'),
        orElse: () => throw 'RX characteristic not found.',
      );

      // Subscribe to notifications
      await _txChar!.setNotifyValue(true);
      _txChar!.lastValueStream.listen(_onNotification);

      // Start continuous capture
      await _rxChar!.write([0x01], withoutResponse: false);

      _statusCtl.add(BluetoothStatus.connected);
    } catch (e) {
      _statusCtl.add(BluetoothStatus.error);
      rethrow;
    }
  }

  void _onNotification(List<int> chunk) {
    if (chunk.isEmpty) return;
    final bytes = Uint8List.fromList(chunk);

    // Detect JPEG start marker (0xFFD8)
    int i = 0;
    while (i < bytes.length - 1) {
      if (!_capturingJpeg &&
          bytes[i] == 0xFF &&
          bytes[i + 1] == 0xD8) {
        _jpegBuf.clear();
        _jpegBuf.add(bytes.sublist(i));
        _capturingJpeg = true;
        break;
      }
      i++;
    }

    if (_capturingJpeg) {
      // Append to buffer; check for end marker (0xFFD9)
      if (i > 0) {
        _jpegBuf.add(bytes.sublist(i));
      }

      final built = _jpegBuf.toBytes();
      if (built.length >= 2 &&
          built[built.length - 2] == 0xFF &&
          built[built.length - 1] == 0xD9) {
        // JPEG complete — emit frame
        _frameCtl.add(FrameData(
          jpegBytes: Uint8List.fromList(built),
          width: 640,  // ESP32-CAM default; firmware can override
          height: 480,
          capturedAt: DateTime.now(),
        ));
        _jpegBuf.clear();
        _capturingJpeg = false;
      }
    }
  }

  /// Tell the ESP32-CAM to send exactly one frame (button-driven mode).
  Future<void> requestOneFrame() async {
    if (_rxChar == null) return;
    await _rxChar!.write([0x02], withoutResponse: false);
  }

  /// Stop the continuous stream (battery saver).
  Future<void> pauseStream() async {
    if (_rxChar == null) return;
    await _rxChar!.write([0x00], withoutResponse: false);
  }

  Future<void> disconnect() async {
    await pauseStream();
    await _device?.disconnect();
    _device = null;
    _txChar = null;
    _rxChar = null;
    _statusCtl.add(BluetoothStatus.disconnected);
  }

  void dispose() {
    _statusCtl.close();
    _frameCtl.close();
  }
}
