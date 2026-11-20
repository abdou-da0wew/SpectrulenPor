import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smart_glass_app/models/glasses_setup.dart';
import 'package:smart_glass_app/services/wifi_udp_video_service.dart';

class _FakeDatagramSocket extends Stream<RawSocketEvent>
    implements RawDatagramSocket {
  final StreamController<RawSocketEvent> _events =
      StreamController<RawSocketEvent>(sync: true);
  final Queue<Datagram> _received = Queue<Datagram>();
  final sent = <List<int>>[];
  bool closed = false;

  void feed(Uint8List data) {
    _received.add(Datagram(data, InternetAddress('192.0.2.20'), 8888));
    _events.add(RawSocketEvent.read);
  }

  @override
  Datagram? receive() => _received.isEmpty ? null : _received.removeFirst();

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    if (closed) throw const SocketException('socket closed');
    sent.add(List<int>.from(buffer));
    if (buffer.length == 1 &&
        buffer.single == WifiUdpVideoService.cmdPeerKeepalive) {
      feed(Uint8List.fromList([...utf8.encode(r'$CMD:keepalive'), 10]));
    }
    return buffer.length;
  }

  @override
  set writeEventsEnabled(bool value) {}

  @override
  void close() {
    if (closed) return;
    closed = true;
    unawaited(_events.close());
  }

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _events.stream.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<Uint8List> _packetize(Uint8List jpeg, {required int frameId}) {
  const payloadSize = WifiUdpVideoService.payloadBytes;
  const groupSize = WifiUdpVideoService.fecGroupSize;
  final total = (jpeg.length + payloadSize - 1) ~/ payloadSize;
  final packets = <Uint8List>[];

  // Data fragments are transmitted in sequence order. Parity groups are
  // strided by sequence modulo groupSize, so adjacent RF losses map to
  // independent recovery groups: {0,4,8...}, {1,5,9...}, etc.
  for (var sequence = 0; sequence < total; sequence++) {
    final offset = sequence * payloadSize;
    final end = (offset + payloadSize).clamp(0, jpeg.length);
    packets.add(_encodePacket(
      sequence: sequence,
      total: total,
      offset: offset,
      payload: jpeg.sublist(offset, end),
      frameId: frameId,
      frameSize: jpeg.length,
    ));
  }

  final groupCount = total < groupSize ? total : groupSize;
  for (var groupIndex = 0; groupIndex < groupCount; groupIndex++) {
    final parity = Uint8List(payloadSize);
    for (var sequence = groupIndex; sequence < total; sequence += groupSize) {
      final offset = sequence * payloadSize;
      final end = (offset + payloadSize).clamp(0, jpeg.length);
      final payload = jpeg.sublist(offset, end);
      for (var i = 0; i < payload.length; i++) {
        parity[i] ^= payload[i];
      }
    }
    packets.add(_encodePacket(
      sequence: groupIndex,
      total: total,
      offset: groupIndex * payloadSize,
      payload: parity,
      frameId: frameId,
      frameSize: jpeg.length,
      parity: true,
    ));
  }
  return packets;
}

Uint8List _encodePacket({
  required int sequence,
  required int total,
  required int offset,
  required List<int> payload,
  required int frameId,
  required int frameSize,
  bool parity = false,
}) {
  final result = Uint8List(WifiUdpVideoService.udpHeaderLen + payload.length);
  final header = ByteData.sublistView(result);
  header.setUint32(
    0,
    parity ? WifiUdpVideoService.paritySequenceFlag | sequence : sequence,
    Endian.little,
  );
  header.setUint32(4, total, Endian.little);
  header.setUint32(8, offset, Endian.little);
  header.setUint32(12, payload.length, Endian.little);
  header.setUint32(16, frameId, Endian.little);
  header.setUint32(20, frameSize, Endian.little);
  result.setRange(WifiUdpVideoService.udpHeaderLen, result.length, payload);
  return result;
}

Uint8List _testJpeg() {
  final bytes = Uint8List(2500);
  bytes[0] = 0xFF;
  bytes[1] = 0xD8;
  for (var i = 2; i < bytes.length - 2; i++) {
    bytes[i] = (i * 37) & 0xFF;
  }
  bytes[bytes.length - 2] = 0xFF;
  bytes[bytes.length - 1] = 0xD9;
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final peer = InternetAddress('192.0.2.20');

  test('V2 frame is reconstructed when UDP datagrams arrive out of order',
      () async {
    final socket = _FakeDatagramSocket();
    final service = WifiUdpVideoService(
      socketFactory: () async => socket,
      frameDecoder: (_) async => [800, 600],
    );
    addTearDown(service.dispose);

    final start = service.start(espIp: peer);
    await Future<void>.delayed(Duration.zero);
    final frameFuture = service.frameStream.first;
    for (final datagram in _packetize(_testJpeg(), frameId: 44).reversed) {
      socket.feed(datagram);
    }

    await start;
    final frame = await frameFuture;
    expect(frame.jpegBytes, _testJpeg());
    expect(frame.width, 800);
    expect(frame.height, 600);
    expect(service.isReady, isTrue);
  });

  test('one lost data datagram is recovered using XOR parity', () async {
    final socket = _FakeDatagramSocket();
    final service = WifiUdpVideoService(
      socketFactory: () async => socket,
      frameDecoder: (_) async => [800, 600],
    );
    addTearDown(service.dispose);

    final start = service.start(espIp: peer);
    await Future<void>.delayed(Duration.zero);
    final frameFuture = service.frameStream.first;
    final datagrams = _packetize(_testJpeg(), frameId: 91);
    var dropped = false;
    for (final datagram in datagrams) {
      final rawSequence =
          ByteData.sublistView(datagram).getUint32(0, Endian.little);
      final isParity =
          (rawSequence & WifiUdpVideoService.paritySequenceFlag) != 0;
      if (!dropped && !isParity && rawSequence == 0) {
        dropped = true;
        continue;
      }
      socket.feed(datagram);
    }

    await start;
    final frame = await frameFuture;
    expect(dropped, isTrue);
    expect(frame.jpegBytes, _testJpeg());
    expect(service.isReady, isTrue);
  });

  test('two adjacent packet losses are recovered by separate strided FEC groups', () async {
    final socket = _FakeDatagramSocket();
    final service = WifiUdpVideoService(
      socketFactory: () async => socket,
      frameDecoder: (_) async => [640, 480],
    );
    addTearDown(service.dispose);

    final jpeg = Uint8List(9000);
    jpeg[0] = 0xFF;
    jpeg[1] = 0xD8;
    jpeg[jpeg.length - 2] = 0xFF;
    jpeg[jpeg.length - 1] = 0xD9;

    final start = service.start(espIp: peer);
    await Future<void>.delayed(Duration.zero);
    final frameFuture = service.frameStream.first;
    final datagrams = _packetize(jpeg, frameId: 92);
    var droppedFirstGroup = false;
    var droppedSecondGroup = false;
    for (final datagram in datagrams) {
      final header = ByteData.sublistView(datagram);
      final rawSequence = header.getUint32(0, Endian.little);
      final isParity =
          (rawSequence & WifiUdpVideoService.paritySequenceFlag) != 0;
      if (!isParity && rawSequence == 0) {
        droppedFirstGroup = true;
        continue;
      }
      if (!isParity && rawSequence == 1) {
        droppedSecondGroup = true;
        continue;
      }
      socket.feed(datagram);
    }

    await start;
    final frame = await frameFuture;
    expect(droppedFirstGroup, isTrue);
    expect(droppedSecondGroup, isTrue);
    expect(frame.jpegBytes, jpeg);
    expect(service.isReady, isTrue);
  });

  test('three adjacent packet losses are recovered by separate strided FEC groups', () async {
    final socket = _FakeDatagramSocket();
    final service = WifiUdpVideoService(
      socketFactory: () async => socket,
      frameDecoder: (_) async => [640, 480],
    );
    addTearDown(service.dispose);

    final jpeg = Uint8List(9000);
    jpeg[0] = 0xFF;
    jpeg[1] = 0xD8;
    jpeg[jpeg.length - 2] = 0xFF;
    jpeg[jpeg.length - 1] = 0xD9;

    final start = service.start(espIp: peer);
    await Future<void>.delayed(Duration.zero);
    final frameFuture = service.frameStream.first;
    final datagrams = _packetize(jpeg, frameId: 93);
    final droppedSequences = <int>{0, 1, 2};
    var dropped = 0;
    for (final datagram in datagrams) {
      final rawSequence = ByteData.sublistView(datagram).getUint32(0, Endian.little);
      final isParity = (rawSequence & WifiUdpVideoService.paritySequenceFlag) != 0;
      final sequence = rawSequence & 0x7FFFFFFF;
      if (!isParity && droppedSequences.contains(sequence)) {
        dropped++;
        continue;
      }
      socket.feed(datagram);
    }

    await start;
    final frame = await frameFuture;
    expect(dropped, 3);
    expect(frame.jpegBytes, jpeg);
    expect(service.isReady, isTrue);
  });

  test('production JPEG decoder publishes the decoded camera dimensions',
      () async {
    final image = img.Image(width: 96, height: 64);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final value = ((x ~/ 4 + y ~/ 4) % 2 == 0) ? 210 : 70;
        image.setPixelRgb(x, y, value, value, value);
      }
    }
    final jpeg = Uint8List.fromList(img.encodeJpg(image, quality: 75));
    final socket = _FakeDatagramSocket();
    final service = WifiUdpVideoService(socketFactory: () async => socket);
    addTearDown(service.dispose);

    final start = service.start(espIp: peer);
    await Future<void>.delayed(Duration.zero);
    final frameFuture = service.frameStream.first;
    for (final datagram in _packetize(jpeg, frameId: 130).reversed) {
      socket.feed(datagram);
    }

    await start;
    final frame = await frameFuture;
    expect(frame.jpegBytes, jpeg);
    expect(frame.width, 96);
    expect(frame.height, 64);
    expect(service.isReady, isTrue);
  });

  test('two losses in one strided FEC group do not produce a corrupt frame', () async {
    final socket = _FakeDatagramSocket();
    final service = WifiUdpVideoService(
      socketFactory: () async => socket,
      readinessTimeout: const Duration(milliseconds: 120),
      frameDecoder: (_) async => [800, 600],
    );
    addTearDown(service.dispose);

    final start = service.start(espIp: peer);
    final failure = expectLater(
      start,
      throwsA(
        isA<GlassesException>().having(
          (error) => error.code,
          'code',
          GlassesFailure.udpTimeout,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final jpeg = Uint8List(10 * WifiUdpVideoService.payloadBytes + 17);
    jpeg[0] = 0xFF;
    jpeg[1] = 0xD8;
    jpeg[jpeg.length - 2] = 0xFF;
    jpeg[jpeg.length - 1] = 0xD9;
    final datagrams = _packetize(jpeg, frameId: 12);
    var dropped = 0;
    for (final datagram in datagrams) {
      final rawSequence =
          ByteData.sublistView(datagram).getUint32(0, Endian.little);
      final isParity =
          (rawSequence & WifiUdpVideoService.paritySequenceFlag) != 0;
      if (!isParity && (rawSequence == 0 || rawSequence == WifiUdpVideoService.fecGroupSize)) {
        dropped++;
        continue;
      }
      socket.feed(datagram);
    }
    await failure;
    expect(dropped, 2);
    expect(service.isReady, isFalse);
  });
}
