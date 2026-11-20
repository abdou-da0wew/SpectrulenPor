import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/models/glasses_setup.dart';
import 'package:smart_glass_app/services/wifi_udp_video_service.dart';

import '../support/glasses_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final peer = InternetAddress('192.0.2.10');

  test('socket loss automatically restores the UDP control channel', () async {
    final first = FakeDatagramSocket();
    final second = FakeDatagramSocket();
    final sockets = <FakeDatagramSocket>[first, second];
    final service = WifiUdpVideoService(
      socketFactory: () async => sockets.removeAt(0),
    );
    addTearDown(service.dispose);

    await service.connect(espIp: peer);
    first.close();
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect(service.isConnected, isTrue);
    expect(service.espIp?.address, peer.address);
    expect(sockets, isEmpty);
  });

  test('start falls back to broadcast discovery when the saved IP is stale',
      () async {
    final stale = FakeDatagramSocket()..failSend = true;
    final discovered = FakeDatagramSocket();
    final sockets = <FakeDatagramSocket>[stale, discovered];
    final service = WifiUdpVideoService(
      socketFactory: () async => sockets.removeAt(0),
      frameDecoder: decodeFixtureJpeg,
    );
    addTearDown(service.dispose);

    final starting = service.start(espIp: peer);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    for (final packet in packetize(testJpeg())) {
      discovered.feed(packet);
    }
    await starting;

    expect(service.isReady, isTrue);
    expect(service.espIp?.address, '192.0.2.10');
    expect(discovered.broadcastEnabled, isTrue);
  });

  test('auto discovery finds the ESP32 from its UDP keepalive echo', () async {
    final socket = FakeDatagramSocket();
    final service = WifiUdpVideoService(socketFactory: () async => socket);
    addTearDown(service.dispose);

    await service.connect();

    expect(service.isConnected, isTrue);
    expect(service.espIp?.address, '192.0.2.10');
    expect(socket.broadcastEnabled, isTrue);
    expect(
      socket.sent.any((packet) =>
          packet.address.address == '255.255.255.255' &&
          packet.bytes.single == WifiUdpVideoService.cmdPeerKeepalive),
      isTrue,
    );
  });

  test(
      'connect-only registers UDP peer and allows runtime status/flash commands without video',
      () async {
    final socket = FakeDatagramSocket();
    final service = WifiUdpVideoService(socketFactory: () async => socket);
    addTearDown(service.dispose);

    await service.connect(espIp: peer);
    expect(service.isConnected, isTrue);
    expect(service.isActive, isTrue);
    expect(service.isStreaming, isFalse);
    expect(service.isReady, isFalse);

    await service.sendCommandAndWait(
      WifiUdpVideoService.cmdFlashOn,
      acknowledgment: r'$CMD:flash_on',
    );
    final status = await service.requestStatus();
    expect(status, startsWith(r'$STATUS:'));
    await service.disconnect();
    expect(socket.closed, isTrue);
  });

  test(
      'peer registration retries when initial keepalive acknowledgements are lost',
      () async {
    final socket = FakeDatagramSocket()..dropPeerKeepaliveAcknowledgements = 2;
    final service = WifiUdpVideoService(socketFactory: () async => socket);
    addTearDown(service.dispose);

    await service.connect(espIp: peer);

    final keepaliveAttempts = socket.sent
        .where((datagram) =>
            datagram.bytes.length == 1 &&
            datagram.bytes.single == WifiUdpVideoService.cmdPeerKeepalive)
        .length;
    expect(keepaliveAttempts, 3);
    expect(service.isConnected, isTrue);
  });

  test('out-of-order fragments are reassembled by frame ID', () async {
    final socket = FakeDatagramSocket();
    final service = WifiUdpVideoService(socketFactory: () async => socket);
    addTearDown(service.dispose);
    final start = service.start(espIp: peer);
    await Future<void>.delayed(Duration.zero);
    final packets = packetize(testJpeg(), frameId: 44);
    final frame = service.frameStream.first;
    for (final data in packets.reversed) {
      socket.feed(data);
    }
    await start;
    final received = await frame;
    expect(received.jpegBytes, testJpeg());
    expect(service.isReady, isTrue);
  });

  test(
      'one missing fragment per FEC group is recovered without a retry round trip',
      () async {
    final socket = FakeDatagramSocket();
    final service = WifiUdpVideoService(socketFactory: () async => socket);
    addTearDown(service.dispose);
    final start = service.start(espIp: peer);
    await Future<void>.delayed(Duration.zero);
    final packets = packetize(testJpeg(), frameId: 77);
    final dataPackets = packets.where((packet) =>
        (ByteData.sublistView(packet).getUint32(0, Endian.little) &
            WifiUdpVideoService.paritySequenceFlag) ==
        0);
    final firstData = dataPackets.first;
    final frame = service.frameStream.first;
    // Intentionally lose the first data datagram; the group's XOR parity
    // packet reconstructs it after all other datagrams arrive.
    var skippedFirstData = false;
    for (final data in packets) {
      final rawSequence =
          ByteData.sublistView(data).getUint32(0, Endian.little);
      if (!skippedFirstData &&
          (rawSequence & WifiUdpVideoService.paritySequenceFlag) == 0) {
        skippedFirstData = true;
        continue;
      }
      socket.feed(data);
    }
    expect(firstData, isNotEmpty);
    await start;
    final received = await frame;
    expect(received.jpegBytes, testJpeg());
    expect(service.isReady, isTrue);
  });

  test('bind and peer echo are not readiness; only decoded JPEG is', () async {
    final socket = FakeDatagramSocket();
    final service = WifiUdpVideoService(socketFactory: () async => socket);
    addTearDown(service.dispose);
    final statuses = <String>[];
    final sub = service.statusStream.listen(statuses.add);
    addTearDown(sub.cancel);
    final start = service.start(espIp: peer);
    await Future<void>.delayed(Duration.zero);
    expect(service.isActive, isTrue);
    expect(service.isReady, isFalse);
    expect(statuses, contains('connecting'));
    expect(socket.sent.map((command) => command.bytes.single).take(2),
        [0x0C, 0x01]);
    socket.feed(Uint8List.fromList([0x01]));
    expect(service.isReady, isFalse);
    final jpeg = testJpeg();
    final frame = service.frameStream.first;
    for (final data in packetize(jpeg)) {
      socket.feed(data);
    }
    await start;
    final received = await frame;
    expect(service.isReady, isTrue);
    expect(received.jpegBytes, jpeg);
    expect(received.width, 96);
    expect(received.height, 64);
    expect(statuses, contains('connected'));
  });

  test('rejects wrong sender/port and malformed bounds without changing peer',
      () async {
    final socket = FakeDatagramSocket();
    final service = WifiUdpVideoService(socketFactory: () async => socket);
    addTearDown(service.dispose);
    final start = service.start(espIp: peer);
    await Future<void>.delayed(Duration.zero);
    final packets = packetize(testJpeg());
    for (final data in packets) {
      socket.feed(data, address: '192.0.2.11');
      socket.feed(data, port: 9999);
    }
    for (final invalid in [
      Uint8List(15),
      packet(seq: 0, total: 0, payload: [1]),
      packet(seq: 1, total: 1, payload: [1]),
      packet(
          seq: 0, total: WifiUdpVideoService.maxPacketCount + 1, payload: [1]),
      packet(seq: 0, total: 1, payload: List.filled(1201, 1)),
      packet(seq: 0, total: 1, payload: [1], size: 512),
      packet(seq: 0, total: 1, payload: [1], size: 0),
      packet(seq: 0, total: 2, payload: [1]),
      packet(seq: 0, total: 1, payload: [1], offset: 1200),
      packet(seq: 1023, total: 1024, payload: [1], offset: 0xFFFFFFFF),
    ]) {
      socket.feed(invalid);
    }
    expect(service.isReady, isFalse);
    expect(service.espIp!.address, peer.address);
    service.sendCommand(WifiUdpVideoService.cmdFlashOff);
    expect(socket.sent.last.address.address, peer.address);
    expect(socket.sent.last.port, 8888);
    for (final data in packets) {
      socket.feed(data);
    }
    await start;
    expect(service.isReady, isTrue);
  });

  test(
      'identical duplicates are ignored and conflicting duplicates drop partial frames',
      () async {
    final socket = FakeDatagramSocket();
    final service = WifiUdpVideoService(socketFactory: () async => socket);
    addTearDown(service.dispose);
    final start = service.start(espIp: peer);
    await Future<void>.delayed(Duration.zero);
    final packets = packetize(testJpeg());
    expect(packets.length, greaterThan(2));
    socket.feed(packets[0]);
    socket.feed(packets[1]);
    final conflicting = Uint8List.fromList(packets[1]);
    conflicting[16] ^= 1;
    socket.feed(conflicting);
    for (final data in packets.skip(2)) {
      socket.feed(data);
    }
    expect(service.isReady, isFalse);
    socket.feed(packets[0]);
    socket.feed(packets[0]);
    for (final data in packets.skip(1)) {
      socket.feed(data);
      socket.feed(data);
    }
    await start;
    expect(service.isReady, isTrue);
  });

  test('gaps, total mismatch and expired assembly never produce a mixed image',
      () async {
    final socket = FakeDatagramSocket();
    final service = WifiUdpVideoService(
        socketFactory: () async => socket,
        frameTimeout: const Duration(milliseconds: 30),
        readinessTimeout: const Duration(seconds: 20));
    addTearDown(service.dispose);
    final start = service.start(espIp: peer);
    await Future<void>.delayed(Duration.zero);
    final packets = packetize(testJpeg());
    socket.feed(packets[0]);
    socket.feed(packets[2]);
    socket.feed(packets[1]);
    expect(service.isReady, isFalse);
    socket.feed(packets[0]);
    final changedTotal = Uint8List.fromList(packets[1]);
    ByteData.sublistView(changedTotal)
        .setUint32(4, packets.length + 1, Endian.little);
    socket.feed(changedTotal);
    expect(service.isReady, isFalse);
    socket.feed(packets[0]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (final data in packets.skip(1)) {
      socket.feed(data);
    }
    expect(service.isReady, isFalse);
    for (final data in packetize(testJpeg(), frameId: 2)) {
      socket.feed(data);
    }
    await start;
  });

  test(
      'JPEG markers alone cannot declare readiness and first-frame timeout preserves UDP controls',
      () async {
    final socket = FakeDatagramSocket();
    final service = WifiUdpVideoService(
        socketFactory: () async => socket,
        readinessTimeout: const Duration(milliseconds: 200));
    addTearDown(service.dispose);
    final start = service.start(espIp: peer);
    final failure = expectLater(
        start,
        throwsA(isA<GlassesException>()
            .having((e) => e.code, 'code', GlassesFailure.udpTimeout)));
    await Future<void>.delayed(Duration.zero);
    socket.feed(packet(seq: 0, total: 1, payload: [0xFF, 0xD8, 0xFF, 0xD9]));
    await failure;
    expect(service.isReady, isFalse);
    expect(service.isActive, isTrue);
    expect(service.isConnected, isTrue);
    expect(socket.closed, isFalse);
    await service.disconnect();
  });

  test('stream stalls invalidate readiness but retain UDP command recovery',
      () async {
    final socket = FakeDatagramSocket();
    final service = WifiUdpVideoService(
        socketFactory: () async => socket,
        stalledTimeout: const Duration(milliseconds: 200));
    addTearDown(service.dispose);
    final stalled =
        service.statusStream.firstWhere((status) => status == 'stalled');
    final start = service.start(espIp: peer);
    await Future<void>.delayed(Duration.zero);
    for (final data in packetize(testJpeg())) {
      socket.feed(data);
    }
    await start;
    socket.feed(Uint8List(16));
    await stalled;
    expect(service.lastFailure, GlassesFailure.udpStalled);
    expect(service.isReady, isFalse);
    expect(service.isActive, isTrue);
    expect(service.isConnected, isTrue);
    final recovered = service.frameStream.first;
    for (final data in packetize(testJpeg(), frameId: 2)) {
      socket.feed(data);
    }
    await recovered;
    expect(service.isReady, isTrue);
  });

  test(
      'pause keeps listener open, single image stays paused and controls stay UDP 0..4',
      () async {
    final socket = FakeDatagramSocket();
    final service = WifiUdpVideoService(socketFactory: () async => socket);
    addTearDown(service.dispose);
    final start = service.start(espIp: peer);
    await Future<void>.delayed(Duration.zero);
    final packets = packetize(testJpeg());
    for (final data in packets) {
      socket.feed(data);
    }
    await start;
    service.sendCommand(0x00);
    expect(service.isActive, isTrue);
    expect(service.isStreaming, isFalse);
    expect(socket.closed, isFalse);
    service.sendCommand(0x02);
    final oneFrame = service.frameStream.first;
    for (final data in packetize(testJpeg(), frameId: 2)) {
      socket.feed(data);
    }
    await oneFrame;
    expect(service.isStreaming, isFalse);
    service.sendCommand(0x03);
    service.sendCommand(0x04);
    await service.sendCommandAndWait(0x05, acknowledgment: r'$CMD:restart');
    await service.sendCommandAndWait(0x06,
        acknowledgment: r'$CMD:shutdown_complete');
    service.sendCommand(0x01);
    expect(service.isStreaming, isTrue);
    await service.stop();
    expect(socket.sent.map((command) => command.bytes.single),
        [0x0C, 0x01, 0x00, 0x02, 0x03, 0x04, 0x05, 0x06, 0x01, 0x00]);
    expect(socket.closed, isFalse);
    expect(service.isConnected, isTrue);
    await service.disconnect();
    expect(socket.closed, isTrue);
  });

  test(
      'bind/send failure and cancellation cannot report success or leak sockets',
      () async {
    final badBind = WifiUdpVideoService(
        socketFactory: () async =>
            throw const SocketException('private address'));
    addTearDown(badBind.dispose);
    await expectLater(
        badBind.start(espIp: peer), throwsA(isA<GlassesException>()));
    final socket = FakeDatagramSocket()..sendResult = 0;
    final badSend = WifiUdpVideoService(socketFactory: () async => socket);
    addTearDown(badSend.dispose);
    await expectLater(
        badSend.start(espIp: peer), throwsA(isA<GlassesException>()));
    expect(socket.closed, isTrue);
    final binding = Completer<RawDatagramSocket>();
    final cancelled = WifiUdpVideoService(socketFactory: () => binding.future);
    addTearDown(cancelled.dispose);
    final start = cancelled.start(espIp: peer);
    final failed = expectLater(start, throwsA(isA<GlassesException>()));
    await cancelled.stop();
    final lateSocket = FakeDatagramSocket();
    binding.complete(lateSocket);
    await failed;
    expect(lateSocket.closed, isTrue);
    expect(cancelled.isReady, isFalse);
  });

  test('manual endpoint accepts only unicast IPv4, never mDNS or broadcast',
      () {
    for (final invalid in [
      '',
      'spectrulenpor-esp32.local',
      '0.0.0.0',
      '127.0.0.1',
      '224.0.0.1',
      '255.255.255.255',
      '::1',
      '300.1.1.1'
    ]) {
      expect(WifiUdpVideoService.parsePeerAddress(invalid), isNull);
    }
    expect(WifiUdpVideoService.parsePeerAddress(peer.address), isNotNull);
  });

  test('readiness deadline cancels a pending bind and closes a late socket',
      () async {
    final binding = Completer<RawDatagramSocket>();
    final service = WifiUdpVideoService(
        socketFactory: () => binding.future,
        readinessTimeout: const Duration(milliseconds: 30));
    addTearDown(service.dispose);
    await expectLater(
        service.start(espIp: peer),
        throwsA(isA<GlassesException>()
            .having((e) => e.code, 'code', GlassesFailure.udpTimeout)));
    final lateSocket = FakeDatagramSocket();
    binding.complete(lateSocket);
    await Future<void>.delayed(Duration.zero);
    expect(lateSocket.closed, isTrue);
    expect(service.isActive, isFalse);
  });

  test('decoder failure is contained and a later valid JPEG can recover',
      () async {
    final socket = FakeDatagramSocket();
    var calls = 0;
    final service = WifiUdpVideoService(
        socketFactory: () async => socket,
        readinessTimeout: const Duration(seconds: 20),
        frameDecoder: (_) async {
          if (++calls == 1) throw StateError('private decoder detail');
          return [96, 64];
        });
    addTearDown(service.dispose);
    final start = service.start(espIp: peer);
    await Future<void>.delayed(Duration.zero);
    final packets = packetize(testJpeg());
    for (final data in packets) {
      socket.feed(data);
    }
    await Future<void>.delayed(Duration.zero);
    expect(service.isReady, isFalse);
    for (final data in packetize(testJpeg(), frameId: 2)) {
      socket.feed(data);
    }
    await start;
    expect(service.isReady, isTrue);
    expect(calls, 2);
  });

  test('a decoded image from a stopped session cannot make a new session ready',
      () async {
    final firstSocket = FakeDatagramSocket();
    final secondSocket = FakeDatagramSocket();
    final decoding = Completer<List<int>?>();
    var binds = 0;
    var decodes = 0;
    final service = WifiUdpVideoService(
        socketFactory: () async => ++binds == 1 ? firstSocket : secondSocket,
        frameDecoder: (_) async {
          if (++decodes == 1) return await decoding.future;
          return [96, 64];
        });
    addTearDown(service.dispose);
    final start = service.start(espIp: peer);
    final cancelled = expectLater(start, throwsA(isA<GlassesException>()));
    await Future<void>.delayed(Duration.zero);
    final packets = packetize(testJpeg());
    for (final data in packets) {
      firstSocket.feed(data);
    }
    await service.disconnect();
    await cancelled;
    final next = service.start(espIp: peer);
    await Future<void>.delayed(Duration.zero);
    decoding.complete([96, 64]);
    await Future<void>.delayed(Duration.zero);
    expect(service.isReady, isFalse);
    for (final data in packets) {
      secondSocket.feed(data);
    }
    await next;
    expect(service.isReady, isTrue);
    expect(firstSocket.closed, isTrue);
    expect(secondSocket.closed, isFalse);
  });

  test(
      'missing paused single-frame response expires without resuming streaming',
      () async {
    final socket = FakeDatagramSocket();
    final service = WifiUdpVideoService(
        socketFactory: () async => socket,
        frameDecoder: (_) async => [96, 64],
        stalledTimeout: const Duration(milliseconds: 30));
    addTearDown(service.dispose);
    final start = service.start(espIp: peer);
    await Future<void>.delayed(Duration.zero);
    for (final data in packetize(testJpeg())) {
      socket.feed(data);
    }
    await start;
    service.sendCommand(0x00);
    service.sendCommand(0x02);
    expect(service.isStreaming, isFalse);
    await service.statusStream.firstWhere((status) => status == 'stalled');
    expect(service.lastFailure, GlassesFailure.udpStalled);
    expect(service.isReady, isFalse);
    expect(service.isConnected, isTrue);
    await service.disconnect();
  });
}
