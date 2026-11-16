import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/models/recognition_state.dart';
import 'package:smart_glass_app/services/bluetooth_camera_service.dart';
import 'package:smart_glass_app/services/wifi_udp_video_service.dart';

import '../support/glasses_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'coordinator advances on exact evidence and persists identity, never password',
      () async {
    final ble = FakeSetupBle();
    addTearDown(ble.service.dispose);
    final state = await setupState(ble: ble.service);
    addTearDown(state.dispose);
    final stages = <GlassesSetupStage>[];
    state.addListener(() => stages.add(state.setupStage));
    await state.setWifiConfig('Lab', 'password1');
    expect(ble.writes.map((bytes) => bytes.first), [0x0A, 0x07, 0x0B]);
    expect(
        stages,
        containsAllInOrder([
          GlassesSetupStage.pairing,
          GlassesSetupStage.provisioning,
          GlassesSetupStage.rebooting,
          GlassesSetupStage.awaitingIp
        ]));
    expect(state.wifiConnected, isFalse);
    expect(state.credentialsSaved, isTrue);
    expect(state.wifiPass, isEmpty);
    expect(state.prefs.getString('glasses_mac'), FakeSetupBle.mac);
    expect(state.prefs.getString('glasses_hostname'),
        BluetoothCameraService.expectedHostname);
    expect(state.prefs.getKeys().any((key) => key.contains('pass')), isFalse);
    expect(state.prefs.getKeys().map(state.prefs.get),
        isNot(contains('password1')));
    expect(state.glassesFailure, isNull);
    ble.feed('\$STATUS:wifi=connected,ip=192.0.2.10\n\$WIFI:connected\n');
    await Future<void>.delayed(Duration.zero);
    expect(state.wifiConnected, isFalse);
    expect(state.wifiIp, isEmpty);
  });

  test(
      'pair failure does not provision or reboot and can be retried explicitly',
      () async {
    final ble = FakeSetupBle(timeout: const Duration(milliseconds: 30));
    addTearDown(ble.service.dispose);
    final state = await setupState(ble: ble.service);
    addTearDown(state.dispose);
    ble.onWrite = (_) => ble.feed('\$CMD:paired_extra\n');
    await state.setWifiConfig('Lab', 'password1');
    expect(state.setupStage, GlassesSetupStage.failed);
    expect(state.glassesFailure, GlassesFailure.acknowledgmentTimeout);
    expect(state.credentialsSaved, isFalse);
    expect(state.configurationUncertain, isFalse);
    expect(ble.writes.map((bytes) => bytes.first), [0x0A]);
    expect(state.canProvision, isTrue);
  });

  test('missing profile evidence never saves identity, reboots or auto-resends',
      () async {
    final ble = FakeSetupBle(timeout: const Duration(milliseconds: 30));
    addTearDown(ble.service.dispose);
    final state = await setupState(ble: ble.service);
    addTearDown(state.dispose);
    ble.onWrite = (bytes) {
      if (bytes.first == 0x0A) {
        ble.feed('${BluetoothCameraService.pairedAck}\n');
      }
      if (bytes.first == 0x07) {
        ble.feed('${BluetoothCameraService.provisionedAck}\n');
      }
    };
    await state.setWifiConfig('Lab', 'password1');
    expect(state.credentialsSaved, isFalse);
    expect(state.configurationUncertain, isTrue);
    expect(state.prefs.getString('glasses_mac'), isNull);
    expect(ble.writes.map((bytes) => bytes.first), [0x0A, 0x07]);
    await state.setWifiConfig('Lab', 'password1');
    expect(ble.writes, hasLength(2));
    expect(state.canProvision, isFalse);
  });

  test('missing reboot ACK keeps saved identity but not a fake WiFi connection',
      () async {
    final ble = FakeSetupBle(timeout: const Duration(milliseconds: 30));
    addTearDown(ble.service.dispose);
    final state = await setupState(ble: ble.service);
    addTearDown(state.dispose);
    ble.onWrite = (bytes) {
      if (bytes.first == 0x0A) {
        ble.feed('${BluetoothCameraService.pairedAck}\n');
      }
      if (bytes.first == 0x07) ble.confirmProfile();
    };
    await state.setWifiConfig('Lab', 'password1');
    expect(state.credentialsSaved, isTrue);
    expect(state.setupStage, GlassesSetupStage.failed);
    expect(state.wifiConnected, isFalse);
    expect(ble.service.reconnectSuppressed, isTrue);
    expect(state.prefs.getString('glasses_mac'), FakeSetupBle.mac);
    await state.setWifiConfig('Lab', 'password1');
    expect(ble.writes, hasLength(3));
  });

  test('pending setup refuses a second request before another write', () async {
    final ble = FakeSetupBle();
    addTearDown(ble.service.dispose);
    final state = await setupState(ble: ble.service);
    addTearDown(state.dispose);
    final release = Completer<void>();
    ble.onWrite = (bytes) async {
      if (bytes.first == 0x0A) {
        await release.future;
        ble.feed('${BluetoothCameraService.pairedAck}\n');
      } else if (bytes.first == 0x07) {
        ble.confirmProfile();
      } else if (bytes.first == 0x0B) {
        ble.feed('${BluetoothCameraService.rebootAck}\n');
        ble.service.debugDisconnectSession();
      }
    };
    final setup = state.setWifiConfig('Lab', 'password1');
    expect(state.setupBusy, isTrue);
    await state.setWifiConfig('Other', 'password2');
    expect(ble.writes, hasLength(1));
    release.complete();
    await setup;
  });

  for (final interruptedCommand in [
    BluetoothCameraService.cmdBlePair,
    BluetoothCameraService.cmdWifiConfigPut,
  ]) {
    test(
        'disconnect during command $interruptedCommand retains write uncertainty',
        () async {
      final ble = FakeSetupBle();
      addTearDown(ble.service.dispose);
      final state = await setupState(ble: ble.service);
      addTearDown(state.dispose);
      final started = Completer<void>();
      final release = Completer<void>();
      ble.onWrite = (bytes) async {
        if (bytes.first == interruptedCommand) {
          started.complete();
          await release.future;
        }
        if (bytes.first == BluetoothCameraService.cmdBlePair) {
          ble.feed('${BluetoothCameraService.pairedAck}\n');
        } else if (bytes.first == BluetoothCameraService.cmdWifiConfigPut) {
          ble.confirmProfile();
        }
      };
      final setup = state.setWifiConfig('Lab', 'password1');
      await started.future;
      await state.disconnect();
      final profileWrite =
          interruptedCommand == BluetoothCameraService.cmdWifiConfigPut;
      expect(state.configurationUncertain, profileWrite);
      expect(state.credentialsSaved, isFalse);
      expect(state.setupBusy, isFalse);
      release.complete();
      await setup;
      expect(state.configurationUncertain, profileWrite);
      expect(state.credentialsSaved, isFalse);
      expect(state.prefs.getString('glasses_mac'), isNull);
      expect(state.prefs.getBool('glasses_wifi_configured'), isNull);
      expect(ble.writes.map((bytes) => bytes.first),
          profileWrite ? [0x0A, 0x07] : [0x0A]);
    });
  }

  test('WiFi-only controls use UDP, preserve pause and reject restart/standby',
      () async {
    final socket = FakeDatagramSocket();
    final udp = WifiUdpVideoService(socketFactory: () async => socket);
    final ble = FakeSetupBle();
    addTearDown(ble.service.dispose);
    final state = await setupState(ble: ble.service, udp: udp, prefs: const {
      'glasses_wifi_configured': true,
      'glasses_mac': FakeSetupBle.mac,
      'glasses_hostname': BluetoothCameraService.expectedHostname
    });
    addTearDown(state.dispose);
    await state.switchSource(CameraSource.glasses);
    ble.writes.clear();
    final start = state.startUdpVideo('192.0.2.10');
    await Future<void>.delayed(Duration.zero);
    expect(state.setupStage, GlassesSetupStage.waitingForFrame);
    expect(state.wifiConnected, isFalse);
    for (final data in packetize(testJpeg())) {
      socket.feed(data);
    }
    await start;
    expect(state.wifiConnected, isTrue);
    expect(state.useUdpVideo, isTrue);
    await state.pauseGlassesStream();
    await state.requestGlassesFrame();
    await state.setFlashlight(true);
    await state.setFlashlight(false);
    expect(udp.isStreaming, isFalse);
    expect(udp.isActive, isTrue);
    expect(ble.writes, isEmpty);
    expect(socket.sent.map((command) => command.bytes.single), [1, 0, 2, 3, 4]);
    expect(state.canUseBleControls, isFalse);
    await state.restartGlasses();
    expect(state.glassesFailure, GlassesFailure.unsupportedControl);
    await state.shutdownGlasses();
    expect(state.wifiConnected, isTrue);
    expect(udp.isActive, isTrue);
    expect(socket.sent, hasLength(5));
    expect(ble.writes, isEmpty);
  });
}
