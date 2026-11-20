import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_glass_app/models/recognition_state.dart';
import 'package:smart_glass_app/services/bluetooth_camera_service.dart';
import 'package:smart_glass_app/services/local_vision_service.dart';
import 'package:smart_glass_app/services/moondream_service.dart';
import 'package:smart_glass_app/services/native_tts_service.dart';
import 'package:smart_glass_app/services/openrouter_service.dart';
import 'package:smart_glass_app/services/openrouter_tts_service.dart';
import 'package:smart_glass_app/services/phone_camera_service.dart';
import 'package:smart_glass_app/services/wifi_udp_video_service.dart';

class FakeSetupBle {
  static const mac = '02:12:34:56:78:90';
  final writes = <List<int>>[];
  FutureOr<void> Function(List<int>)? onWrite;
  late final BluetoothCameraService service;

  FakeSetupBle({Duration timeout = const Duration(seconds: 5)}) {
    service = BluetoothCameraService.forTest(
      acknowledgmentTimeout: timeout,
      rebootDisconnectTimeout: timeout,
      commandWriter: (bytes) async {
        writes.add(List<int>.from(bytes));
        if (onWrite != null) {
          await onWrite!(bytes);
          return;
        }
        switch (bytes.first) {
          case BluetoothCameraService.cmdBlePair:
            feed('${BluetoothCameraService.pairedAck}\n');
          case BluetoothCameraService.cmdWifiConfigPut:
            confirmProfile();
          case BluetoothCameraService.cmdReboot:
            feed('${BluetoothCameraService.rebootAck}\n');
            service.debugDisconnectSession();
          case BluetoothCameraService.cmdStreamOn:
            feed('\$CMD:stream_on\n');
          case BluetoothCameraService.cmdStreamOff:
            feed('\$CMD:stream_off\n');
          case BluetoothCameraService.cmdSingleFrame:
            feed('\$CMD:single_frame\n');
          case BluetoothCameraService.cmdFlashOn:
            feed('\$CMD:flash_on\n');
          case BluetoothCameraService.cmdFlashOff:
            feed('\$CMD:flash_off\n');
          case BluetoothCameraService.cmdRestart:
            feed('\$CMD:restart\n');
          case BluetoothCameraService.cmdShutdown:
            feed('\$CMD:shutdown_complete\n');
        }
      },
    );
  }

  void feed(String text) => service.debugFeedNotification(utf8.encode(text));

  void confirmProfile() => feed(
        '${BluetoothCameraService.provisionedAck}\n'
        '\$ESP_MAC:$mac\n'
        '\$ESP_NAME:${BluetoothCameraService.expectedHostname}\n',
      );
}

/// Uses the production socket listener without opening a network socket.
class FakeDatagramSocket extends Stream<RawSocketEvent>
    implements RawDatagramSocket {
  final _events = StreamController<RawSocketEvent>(sync: true);
  final _received = Queue<Datagram>();
  final sent = <({List<int> bytes, InternetAddress address, int port})>[];
  bool closed = false;
  bool broadcastEnabled = false;
  bool failSend = false;
  int? sendResult;
  int dropPeerKeepaliveAcknowledgements = 0;

  void feed(
    Uint8List data, {
    String address = '192.0.2.10',
    int port = WifiUdpVideoService.udpVideoPort,
  }) {
    _received.add(Datagram(data, InternetAddress(address), port));
    _events.add(RawSocketEvent.read);
  }

  @override
  Datagram? receive() => _received.isEmpty ? null : _received.removeFirst();

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    if (closed || failSend) {
      throw const SocketException('private socket detail');
    }
    sent.add((bytes: List<int>.from(buffer), address: address, port: port));
    if (address.address == '255.255.255.255' &&
        buffer.length == 1 &&
        buffer.single == WifiUdpVideoService.cmdPeerKeepalive) {
      feed(Uint8List.fromList([WifiUdpVideoService.cmdPeerKeepalive]));
    }
    if (buffer.length == 1) {
      final acknowledgment = switch (buffer.single) {
        WifiUdpVideoService.cmdPeerKeepalive => r'$CMD:keepalive',
        WifiUdpVideoService.cmdFlashOn => r'$CMD:flash_on',
        WifiUdpVideoService.cmdFlashOff => r'$CMD:flash_off',
        WifiUdpVideoService.cmdRestart => r'$CMD:restart',
        WifiUdpVideoService.cmdShutdown => r'$CMD:shutdown_complete',
        WifiUdpVideoService.cmdReboot => r'$CMD:reboot',
        WifiUdpVideoService.cmdStreamOn => r'$CMD:stream_on',
        WifiUdpVideoService.cmdStreamOff => r'$CMD:stream_off',
        WifiUdpVideoService.cmdSingleFrame => r'$CMD:single_frame',
        WifiUdpVideoService.cmdConnectionStatus =>
          r'$STATUS:bt=0,wifi=connected,ip=192.0.2.10,flash=0,stream=0',
        _ => null,
      };
      final dropKeepaliveAck =
          buffer.single == WifiUdpVideoService.cmdPeerKeepalive &&
              dropPeerKeepaliveAcknowledgements > 0;
      if (dropKeepaliveAck) {
        dropPeerKeepaliveAcknowledgements--;
      } else if (acknowledgment != null) {
        feed(Uint8List.fromList(utf8.encode('$acknowledgment\n')));
      }
    }
    return sendResult ?? buffer.length;
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

Uint8List testJpeg() {
  final image = img.Image(width: 96, height: 64);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final v = ((x ~/ 4 + y ~/ 4) % 2 == 0) ? 210 : 70;
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

/// Decodes real fixture JPEGs without spawning an isolate in widget fake time.
Future<List<int>?> decodeFixtureJpeg(Uint8List jpeg) async {
  final decoded = img.decodeJpg(jpeg);
  return decoded == null ? null : [decoded.width, decoded.height];
}

List<Uint8List> packetize(Uint8List jpeg, {int frameId = 1}) {
  final payloadSize = WifiUdpVideoService.payloadBytes;
  final groupSize = WifiUdpVideoService.fecGroupSize;
  final total = (jpeg.length + payloadSize - 1) ~/ payloadSize;
  final packets = <Uint8List>[];

  for (var seq = 0; seq < total; seq++) {
    final offset = seq * payloadSize;
    final chunk =
        jpeg.sublist(offset, (offset + payloadSize).clamp(0, jpeg.length));
    packets.add(packet(
      seq: seq,
      total: total,
      payload: chunk,
      frameId: frameId,
      frameSize: jpeg.length,
    ));
  }

  final groupCount = total < groupSize ? total : groupSize;
  for (var groupIndex = 0; groupIndex < groupCount; groupIndex++) {
    final parity = Uint8List(payloadSize);
    for (var seq = groupIndex; seq < total; seq += groupSize) {
      final offset = seq * payloadSize;
      final chunk =
          jpeg.sublist(offset, (offset + payloadSize).clamp(0, jpeg.length));
      for (var i = 0; i < chunk.length; i++) {
        parity[i] ^= chunk[i];
      }
    }
    packets.add(packet(
      seq: groupIndex,
      total: total,
      payload: parity,
      frameId: frameId,
      frameSize: jpeg.length,
      parity: true,
      offset: groupIndex * payloadSize,
    ));
  }
  return packets;
}

Uint8List packet({
  required int seq,
  required int total,
  required List<int> payload,
  int? offset,
  int? size,
  int frameId = 1,
  int? frameSize,
  bool parity = false,
}) {
  final declaredFrameSize =
      frameSize ?? total * WifiUdpVideoService.payloadBytes;
  final data = Uint8List(WifiUdpVideoService.udpHeaderLen + payload.length);
  final header = ByteData.sublistView(data);
  header.setUint32(
    0,
    parity ? (WifiUdpVideoService.paritySequenceFlag | seq) : seq,
    Endian.little,
  );
  header.setUint32(4, total, Endian.little);
  header.setUint32(
    8,
    offset ?? seq * WifiUdpVideoService.payloadBytes,
    Endian.little,
  );
  header.setUint32(12, size ?? payload.length, Endian.little);
  header.setUint32(16, frameId, Endian.little);
  header.setUint32(20, declaredFrameSize, Endian.little);
  data.setRange(WifiUdpVideoService.udpHeaderLen, data.length, payload);
  return data;
}

Future<RecognitionState> setupState({
  required BluetoothCameraService ble,
  WifiUdpVideoService? udp,
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  return RecognitionState(
    bluetooth: ble,
    udpVideo: udp,
    phoneCamera: PhoneCameraService(),
    vision: LocalVisionService.forTest(
      moondream: MoondreamService()..apiKey = '',
    ),
    openRouter: OpenRouterService(apiKey: ''),
    openRouterTts: OpenRouterTtsService.instance,
    nativeTts: NativeTtsService.instance,
    prefs: await SharedPreferences.getInstance(),
  );
}
