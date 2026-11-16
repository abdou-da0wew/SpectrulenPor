import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/models/glasses_setup.dart';
import 'package:smart_glass_app/services/bluetooth_camera_service.dart';

import '../support/glasses_fakes.dart';

Matcher failsWith(GlassesFailure code) =>
    throwsA(isA<GlassesException>().having((e) => e.code, 'code', code));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'fresh exact fragmented pair ACK, profile identity, reboot disconnect',
    () async {
      final ble = FakeSetupBle();
      final service = ble.service;
      addTearDown(service.dispose);
      ble.feed('${BluetoothCameraService.pairedAck}\n');
      expect(service.isPaired, isFalse);
      ble.onWrite = (bytes) {
        if (bytes.first == BluetoothCameraService.cmdBlePair) {
          ble.feed('\$CMD:pai');
          ble.feed('red\r\n\$STATUS:bt=1\n\$UV:1;IR:2\n');
        } else if (bytes.first == BluetoothCameraService.cmdWifiConfigPut) {
          ble.feed(
            '${BluetoothCameraService.provisionedAck}\n\$ESP_MAC:02:12:',
          );
          ble.feed('34:56:78:90\n\$ESP_NAME:spectrulen');
          ble.feed('por-esp32\n');
        } else if (bytes.first == BluetoothCameraService.cmdReboot) {
          expect(service.reconnectSuppressed, isTrue);
          ble.feed('${BluetoothCameraService.rebootAck}\n');
          service.debugDisconnectSession();
        }
      };
      await service.blePair('11111');
      expect(service.isPaired, isTrue);
      await service.wifiConfigPut('Lab network', 'password1');
      expect(service.isWifiConfigured, isTrue);
      expect(ble.writes[0], [0x0A, ...ascii.encode('11111')]);
      expect(ble.writes[1], [
        0x07,
        ...utf8.encode('Lab network'),
        0,
        ...utf8.encode('password1'),
        0,
      ]);
      await service.reboot();
      expect(ble.writes[2], [0x0B]);
      expect(service.isPaired, isFalse);
      expect(service.isWifiConfigured, isFalse);
      expect(service.isConnected, isFalse);
      expect(service.reconnectSuppressed, isTrue);
      expect(service.espMacAddress, FakeSetupBle.mac);
      expect(service.espHostname, BluetoothCameraService.expectedHostname);
    },
  );

  test(
    'cached, similar and partial ACKs cannot authorize a connection',
    () async {
      final ble = FakeSetupBle(timeout: const Duration(milliseconds: 30));
      addTearDown(ble.service.dispose);
      ble.feed('${BluetoothCameraService.pairedAck}\n');
      ble.onWrite = (_) {
        ble.feed('\$CMD:paired_extra\n\$CMD:paired \n\$CMD:paired');
      };
      await expectLater(
        ble.service.blePair('11111'),
        failsWith(GlassesFailure.acknowledgmentTimeout),
      );
      expect(ble.service.isPaired, isFalse);
      await expectLater(
        ble.service.wifiConfigPut('Lab', 'password1'),
        failsWith(GlassesFailure.pairingRequired),
      );
      expect(ble.writes, hasLength(1));
    },
  );

  test(
    'a write failure propagates safely and never grants authorization',
    () async {
      final ble = FakeSetupBle();
      addTearDown(ble.service.dispose);
      ble.onWrite = (_) => throw StateError('secret internal transport detail');
      await expectLater(
        ble.service.blePair('11111'),
        failsWith(GlassesFailure.bleWriteFailed),
      );
      expect(ble.service.isPaired, isFalse);
      final disconnected = BluetoothCameraService();
      addTearDown(disconnected.dispose);
      await expectLater(
        disconnected.pauseStream(),
        failsWith(GlassesFailure.bleUnavailable),
      );
    },
  );

  test('profile needs new MAC and hostname, not retained identity', () async {
    final ble = FakeSetupBle(timeout: const Duration(milliseconds: 30));
    addTearDown(ble.service.dispose);
    await ble.service.blePair('11111');
    ble.service.espMacAddress = FakeSetupBle.mac;
    ble.service.espHostname = BluetoothCameraService.expectedHostname;
    ble.onWrite = (_) => ble.feed('${BluetoothCameraService.provisionedAck}\n');
    await expectLater(
      ble.service.wifiConfigPut('Lab', ''),
      failsWith(GlassesFailure.acknowledgmentTimeout),
    );
    expect(ble.service.isWifiConfigured, isFalse);
    expect(ble.service.espMacAddress, FakeSetupBle.mac);
  });

  for (final identity in [
    '\$ESP_MAC:00:00:00:00:00:00\n',
    '\$ESP_MAC:01:12:34:56:78:90\n',
    '\$ESP_MAC:not-a-mac\n',
    '\$ESP_NAME:unexpected-host\n',
  ]) {
    test('rejects invalid identity $identity', () async {
      final ble = FakeSetupBle();
      addTearDown(ble.service.dispose);
      await ble.service.blePair('11111');
      ble.onWrite = (_) =>
          ble.feed('${BluetoothCameraService.provisionedAck}\n$identity');
      await expectLater(
        ble.service.wifiConfigPut('Lab', 'password1'),
        failsWith(GlassesFailure.invalidIdentity),
      );
      expect(ble.service.isWifiConfigured, isFalse);
    });
  }

  test(
    'credential validation uses UTF-8 byte limits and allows open networks',
    () async {
      expect(BluetoothCameraService.validCredentials('Lab', ''), isTrue);
      expect(BluetoothCameraService.validCredentials('Lab', 'a' * 8), isTrue);
      expect(BluetoothCameraService.validCredentials('Lab', 'a' * 63), isTrue);
      expect(BluetoothCameraService.validCredentials('Lab', 'b' * 64), isTrue);
      expect(BluetoothCameraService.validCredentials('Lab', 'z' * 64), isFalse);
      expect(BluetoothCameraService.validCredentials('Lab', 'a' * 7), isFalse);
      expect(BluetoothCameraService.validCredentials('Lab', 'a' * 65), isFalse);
      expect(BluetoothCameraService.validCredentials('é' * 16, ''), isTrue);
      expect(BluetoothCameraService.validCredentials('é' * 17, ''), isFalse);
      expect(BluetoothCameraService.validCredentials('', ''), isFalse);
      expect(
        BluetoothCameraService.validCredentials('Lab\x00suffix', ''),
        isFalse,
      );
      expect(
        BluetoothCameraService.validCredentials('Lab', 'pass\x00word'),
        isFalse,
      );
      final ble = FakeSetupBle();
      addTearDown(ble.service.dispose);
      await ble.service.blePair('11111');
      await expectLater(
        ble.service.wifiConfigPut('Lab', 'short'),
        failsWith(GlassesFailure.invalidCredentials),
      );
      expect(ble.writes, hasLength(1));
    },
  );

  test('reboot ACK alone does not confirm disconnection', () async {
    final ble = FakeSetupBle(timeout: const Duration(milliseconds: 30));
    addTearDown(ble.service.dispose);
    await ble.service.blePair('11111');
    await ble.service.wifiConfigPut('Lab', 'password1');
    ble.onWrite = (_) => ble.feed('${BluetoothCameraService.rebootAck}\n');
    await expectLater(
      ble.service.reboot(),
      failsWith(GlassesFailure.rebootTimeout),
    );
    expect(ble.service.reconnectSuppressed, isTrue);
  });

  test(
    'disconnect without reboot ACK fails and clears connection authorization',
    () async {
      final ble = FakeSetupBle();
      addTearDown(ble.service.dispose);
      await ble.service.blePair('11111');
      await ble.service.wifiConfigPut('Lab', 'password1');
      ble.onWrite = (_) => ble.service.debugDisconnectSession();
      await expectLater(
        ble.service.reboot(),
        failsWith(GlassesFailure.connectionLost),
      );
      expect(ble.service.isPaired, isFalse);
      expect(ble.service.reconnectSuppressed, isTrue);
    },
  );

  test(
    'overlapping setup commands are rejected without another write',
    () async {
      final ble = FakeSetupBle();
      addTearDown(ble.service.dispose);
      final release = Completer<void>();
      ble.onWrite = (_) async {
        await release.future;
        ble.feed('${BluetoothCameraService.pairedAck}\n');
      };
      final first = ble.service.blePair('11111');
      await expectLater(
        ble.service.blePair('11111'),
        failsWith(GlassesFailure.busy),
      );
      expect(ble.writes, hasLength(1));
      release.complete();
      await first;
    },
  );

  test('profile confirmation followed by disconnect cannot configure a session',
      () async {
    final ble = FakeSetupBle();
    addTearDown(ble.service.dispose);
    await ble.service.blePair(BluetoothCameraService.blePairingCode);
    ble.onWrite = (_) {
      ble.confirmProfile();
      ble.service.debugDisconnectSession();
    };
    await expectLater(ble.service.wifiConfigPut('Lab', 'password1'),
        failsWith(GlassesFailure.connectionLost));
    expect(ble.service.isWifiConfigured, isFalse);
    expect(ble.service.isPaired, isFalse);
    expect(ble.service.espMacAddress, isNull);
    expect(ble.service.espHostname, isNull);
  });

  test('manual disconnect cannot substitute for observed reboot disconnection',
      () async {
    final ble = FakeSetupBle();
    addTearDown(ble.service.dispose);
    await ble.service.blePair(BluetoothCameraService.blePairingCode);
    await ble.service.wifiConfigPut('Lab', 'password1');
    ble.onWrite = (_) => ble.feed('${BluetoothCameraService.rebootAck}\n');
    final reboot = ble.service.reboot();
    final failure =
        expectLater(reboot, failsWith(GlassesFailure.connectionLost));
    await Future<void>.delayed(Duration.zero);
    await ble.service.disconnect();
    await failure;
    expect(ble.service.isConnected, isFalse);
    expect(ble.service.reconnectSuppressed, isTrue);
    expect(ble.writes.map((bytes) => bytes.first), [0x0A, 0x07, 0x0B]);
  });

  test(
      'reboot owns the operation until disconnect and busy calls preserve authorization',
      () async {
    final ble = FakeSetupBle();
    addTearDown(ble.service.dispose);
    await ble.service.blePair(BluetoothCameraService.blePairingCode);
    await ble.service.wifiConfigPut('Lab', 'password1');
    ble.onWrite = (_) => ble.feed('${BluetoothCameraService.rebootAck}\n');
    final reboot = ble.service.reboot();
    await Future<void>.delayed(Duration.zero);
    await expectLater(ble.service.reboot(), failsWith(GlassesFailure.busy));
    await expectLater(
        ble.service.blePair(BluetoothCameraService.blePairingCode),
        failsWith(GlassesFailure.busy));
    await expectLater(ble.service.wifiConfigPut('Other', 'password2'),
        failsWith(GlassesFailure.busy));
    await expectLater(
        ble.service.pauseStream(), failsWith(GlassesFailure.busy));
    expect(ble.service.isPaired, isTrue);
    expect(ble.service.isWifiConfigured, isTrue);
    expect(ble.writes, hasLength(3));
    ble.service.debugDisconnectSession();
    await reboot;
  });

  test('disposal fails a reboot waiter even after the matching ACK', () async {
    final ble = FakeSetupBle();
    await ble.service.blePair(BluetoothCameraService.blePairingCode);
    await ble.service.wifiConfigPut('Lab', 'password1');
    ble.onWrite = (_) => ble.feed('${BluetoothCameraService.rebootAck}\n');
    final reboot = ble.service.reboot();
    final failure =
        expectLater(reboot, failsWith(GlassesFailure.connectionLost));
    await Future<void>.delayed(Duration.zero);
    ble.service.dispose();
    await failure;
    expect(ble.service.isPaired, isFalse);
    expect(ble.service.isWifiConfigured, isFalse);
    ble.feed('${BluetoothCameraService.pairedAck}\n');
  });

  test(
      'an ACK does not hide a failed ATT write or an indefinitely pending write',
      () async {
    final ble = FakeSetupBle(timeout: const Duration(milliseconds: 30));
    addTearDown(ble.service.dispose);
    ble.onWrite = (_) {
      ble.feed('${BluetoothCameraService.pairedAck}\n');
      throw StateError('private write detail');
    };
    await expectLater(
        ble.service.blePair(BluetoothCameraService.blePairingCode),
        failsWith(GlassesFailure.bleWriteFailed));
    final blocked = Completer<void>();
    ble.onWrite = (_) async {
      ble.feed('${BluetoothCameraService.pairedAck}\n');
      await blocked.future;
    };
    await expectLater(
        ble.service.blePair(BluetoothCameraService.blePairingCode),
        failsWith(GlassesFailure.bleWriteFailed));
    expect(ble.service.isPaired, isFalse);
    blocked.complete();
  });
}
