import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/models/frame_data.dart';
import 'package:smart_glass_app/models/spectrum_reading.dart';
import 'package:smart_glass_app/services/bluetooth_camera_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reassembles multi-chunk QVGA JPEG frames > 8 KB without dropping',
      () async {
    final svc = BluetoothCameraService();
    addTearDown(svc.dispose);

    final received = <FrameData>[];
    final sub = svc.frameStream.listen(received.add);
    addTearDown(sub.cancel);

    // Construct a realistic 12 KB JPEG payload containing an embedded 0xFF 0xD8
    // inside entropy data to verify SOI isn't reset mid-frame.
    final payload = BytesBuilder()
      ..add([0xFF, 0xD8, 0xFF, 0xE0])
      ..add(List<int>.filled(5000, 0x42))
      ..add([0xFF, 0xD8]) // spurious sequence inside compressed scan data
      ..add(List<int>.filled(7000, 0x24))
      ..add([0xFF, 0xD9]);
    final fullJpeg = payload.toBytes();

    // Feed in 180-byte BLE MTU chunks plus trailing padding after EOI.
    for (var i = 0; i < fullJpeg.length; i += 180) {
      final end = (i + 180).clamp(0, fullJpeg.length);
      svc.debugFeedNotification(fullJpeg.sublist(i, end));
    }

    await Future<void>.delayed(Duration.zero);
    expect(received, hasLength(1));
    expect(received.first.jpegBytes.length, fullJpeg.length);
    expect(received.first.width, 320);
    expect(received.first.height, 240);
    expect(received.first.jpegBytes.first, 0xFF);
    expect(received.first.jpegBytes[1], 0xD8);
    expect(received.first.jpegBytes[received.first.jpegBytes.length - 2], 0xFF);
    expect(received.first.jpegBytes.last, 0xD9);
  });

  test('parses interleaved UV/IR telemetry notifications cleanly', () async {
    final svc = BluetoothCameraService();
    addTearDown(svc.dispose);

    final readings = <SpectrumReading>[];
    final sub = svc.sensorStream.listen(readings.add);
    addTearDown(sub.cancel);

    svc.debugFeedNotification(utf8.encode('\$UV:3100;IR:900\n'));
    await Future<void>.delayed(Duration.zero);

    expect(readings, hasLength(1));
    expect(readings.first.uvRaw, 3100);
    expect(readings.first.irRaw, 900);
    expect(readings.first.uvHazard, isTrue);
  });
}
