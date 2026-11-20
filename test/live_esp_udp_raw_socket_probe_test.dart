import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('physical ESP32 raw UDP socket can register and receive response', () async {
    final ip = Platform.environment['ESP32_TEST_IP'];
    if (ip == null || ip.isEmpty) {
      markTestSkipped('Set ESP32_TEST_IP to run against the physical board.');
      return;
    }
    final peer = InternetAddress.tryParse(ip);
    expect(peer, isNotNull);

    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
      reuseAddress: false,
    );
    addTearDown(socket.close);
    socket.writeEventsEnabled = false;
    // ignore: avoid_print
    print('RAW_TEST pid=' + pid.toString() +
        ' netns=' + Link('/proc/self/ns/net').targetSync() +
        ' local=' + socket.address.address + ':' + socket.port.toString() +
        ' remote=' + peer!.address + ':8888');

    final response = Completer<String>();
    final subscription = socket.listen((event) {
      if (event != RawSocketEvent.read || response.isCompleted) return;
      while (true) {
        final datagram = socket.receive();
        if (datagram == null) break;
        final text = String.fromCharCodes(datagram.data);
        // ignore: avoid_print
        print('RAW_TEST_RX ' + datagram.address.address + ':' +
            datagram.port.toString() + ' len=' +
            datagram.data.length.toString() + ' text=' +
            text.replaceAll('\n', r'\n'));
        if (datagram.address.address == peer.address &&
            datagram.port == 8888 &&
            text == r'$CMD:keepalive' + '\n') {
          response.complete(text);
        }
      }
    });
    addTearDown(subscription.cancel);

    for (var attempt = 0; attempt < 10 && !response.isCompleted; attempt++) {
      final sent = socket.send(Uint8List.fromList([0x0c]), peer, 8888);
      // ignore: avoid_print
      print('RAW_TEST_TX attempt=' + attempt.toString() +
          ' sent=' + sent.toString());
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }

    expect(
      await response.future.timeout(const Duration(seconds: 4)),
      r'$CMD:keepalive' + '\n',
    );
  }, timeout: const Timeout(Duration(seconds: 15)));
}
