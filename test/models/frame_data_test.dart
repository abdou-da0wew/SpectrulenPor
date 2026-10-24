import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/models/frame_data.dart';

void main() {
  test('sizeKb rounds the JPEG size', () {
    final frame = FrameData(
      jpegBytes: Uint8List(2048),
      width: 640,
      height: 480,
      capturedAt: DateTime(2026),
    );
    expect(frame.sizeKb, 2);
  });

  test('carries capture metadata', () {
    final t = DateTime.now();
    final frame = FrameData(
      jpegBytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
      width: 320,
      height: 240,
      capturedAt: t,
    );
    expect(frame.width, 320);
    expect(frame.height, 240);
    expect(frame.capturedAt, t);
    expect(frame.jpegBytes, hasLength(4));
  });
}
