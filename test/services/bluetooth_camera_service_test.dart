import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/models/spectrum_reading.dart';
import 'package:smart_glass_app/services/bluetooth_camera_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('BLE never publishes camera JPEG frames', () async {
    final service = BluetoothCameraService();
    addTearDown(service.dispose);

    final received = <Object>[];
    final subscription = service.frameStream.listen(received.add);
    addTearDown(subscription.cancel);

    // A complete JPEG and deliberately fragmented JPEG are both forbidden on
    // GATT. The camera data channel is WiFi UDP only.
    final jpeg = <int>[
      0xFF,
      0xD8,
      0xFF,
      0xE0,
      ...List<int>.filled(700, 0x42),
      0xFF,
      0xD9,
    ];
    service.debugFeedNotification(jpeg);
    service.debugFeedNotification(jpeg.sublist(0, 120));
    service.debugFeedNotification(jpeg.sublist(120));

    await Future<void>.delayed(Duration.zero);
    expect(received, isEmpty);
  });

  test('parses setup telemetry text without treating it as camera video',
      () async {
    final service = BluetoothCameraService();
    addTearDown(service.dispose);

    final readings = <SpectrumReading>[];
    final subscription = service.sensorStream.listen(readings.add);
    addTearDown(subscription.cancel);

    service.debugFeedNotification(utf8.encode(r'$UV:3100;IR:900' '\n'));
    await Future<void>.delayed(Duration.zero);

    expect(readings, hasLength(1));
    expect(readings.first.uvRaw, 3100);
    expect(readings.first.irRaw, 900);
    expect(readings.first.uvHazard, isTrue);
  });
}
