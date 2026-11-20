import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/models/bluetooth_status.dart';
import 'package:smart_glass_app/models/glasses_setup.dart';
import 'package:smart_glass_app/services/bluetooth_camera_service.dart';

import '../support/ble_acquisition_fakes.dart';

Matcher failsWith(GlassesFailure code) =>
    throwsA(isA<GlassesException>().having((e) => e.code, 'code', code));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BluetoothCameraService service;
  late FakeAcquisitionDevice device;

  setUp(() {
    service = BluetoothCameraService();
    device = FakeAcquisitionDevice();
  });

  tearDown(() async {
    service.dispose();
    await service.debugCleanupComplete;
    await device.close();
  });

  for (final stage in BleAcquisitionStage.values) {
    test('$stage failure releases the acquired link and subscriptions',
        () async {
      device.failures[stage] = StateError('private acquisition detail');
      Object? failure;
      try {
        await service.debugConnectDevice(device);
      } catch (error) {
        failure = error;
      }
      expect(device.connected, isFalse);
      expect(device.disconnectQueues, isNotEmpty);
      expect(device.connectionEvents.activeListeners, 0);
      expect(device.notifications.activeListeners, 0);
      expect(service.isConnected, isFalse);
      expect(service.isPaired, isFalse);
      expect(service.isWifiConfigured, isFalse);
      expect(device.writes, isEmpty);
      expect(failure, isA<GlassesException>());
      device.failures.clear();
      await service.debugConnectDevice(device);
      expect(service.isConnected, isTrue);
    });
  }

  test('acquisition failure remains primary when all releases fail', () async {
    const original = GlassesException(GlassesFailure.invalidIdentity);
    device.failures[BleAcquisitionStage.subscribe] = original;
    device.connectionEvents.cancelFailure = StateError('private cancel detail');
    device.notifications.cancelFailure = StateError('private notify detail');
    device.disconnectFailure = StateError('private disconnect detail');
    await expectLater(
        service.debugConnectDevice(device), throwsA(same(original)));
    expect(device.connectionEvents.cancelCalls, 1);
    expect(device.notifications.cancelCalls, 1);
    expect(device.disconnectQueues, hasLength(1));
    expect(service.isConnected, isFalse);
    expect(device.writes, isEmpty);
  });

  test('a connect error after physical acquisition still releases the device',
      () async {
    device.onStage = (_) {
      device.connected = true;
    };
    device.failures[BleAcquisitionStage.connect] =
        StateError('private connect detail');
    await expectLater(service.debugConnectDevice(device),
        failsWith(GlassesFailure.bleUnavailable));
    expect(device.connected, isFalse);
    expect(device.disconnectQueues, hasLength(1));
  });

  for (final connection in [false, true]) {
    test(
        'a synchronous ${connection ? 'connection' : 'notification'} event during subscription attachment cannot leak the returned subscription',
        () async {
      if (connection) {
        device.connectionEvents.onListen = device.dropConnection;
      } else {
        device.notifications.onListen = () =>
            device.notifications.addError(StateError('private stream detail'));
      }
      await expectLater(service.debugConnectDevice(device),
          failsWith(GlassesFailure.connectionLost));
      await service.debugCleanupComplete;
      expect(device.connected, isFalse);
      expect(device.connectionEvents.activeListeners, 0);
      expect(device.notifications.activeListeners, 0);
    });
  }

  for (final missing in ['service', 'tx', 'rx']) {
    test('missing $missing is safe and releases the acquired device', () async {
      device.missingService = missing == 'service';
      device.missingTx = missing == 'tx';
      device.missingRx = missing == 'rx';
      await expectLater(service.debugConnectDevice(device),
          failsWith(GlassesFailure.bleUnavailable));
      expect(device.connected, isFalse);
      expect(device.connectionEvents.activeListeners, 0);
      expect(device.notifications.activeListeners, 0);
    });
  }

  for (final connection in [false, true]) {
    test(
        'a failed late ${connection ? 'connection' : 'notification'} subscription release remains owned for explicit close',
        () async {
      if (connection) {
        device.connectionEvents.failBeforeCancel = true;
        device.connectionEvents.cancelFailure =
            StateError('private late cancel detail');
        device.connectionEvents.onListen = device.dropConnection;
      } else {
        device.notifications.failBeforeCancel = true;
        device.notifications.cancelFailure =
            StateError('private late cancel detail');
        device.notifications.onListen = () =>
            device.notifications.addError(StateError('private stream detail'));
      }
      await expectLater(service.debugConnectDevice(device),
          failsWith(GlassesFailure.connectionLost));
      await service.debugCleanupComplete;
      expect(
          connection
              ? device.connectionEvents.activeListeners
              : device.notifications.activeListeners,
          1);
      device.connectionEvents.cancelFailure = null;
      device.notifications.cancelFailure = null;
      await service.disconnect();
      expect(device.connectionEvents.activeListeners, 0);
      expect(device.notifications.activeListeners, 0);
      expect(device.connected, isFalse);
      expect(device.disconnectQueues, hasLength(1));
      expect(device.writes, isEmpty);
    });
  }

  for (final release in ['connection', 'notification', 'device']) {
    test('disconnect independently releases resources after $release failure',
        () async {
      await service.debugConnectDevice(device);
      final failure = StateError('private release detail');
      if (release == 'connection') {
        device.connectionEvents.cancelFailure = failure;
      } else if (release == 'notification') {
        device.notifications.cancelFailure = failure;
      } else {
        device.disconnectFailure = failure;
      }
      await expectLater(
          service.disconnect(), failsWith(GlassesFailure.connectionLost));
      expect(device.connectionEvents.cancelCalls, 1);
      expect(device.notifications.cancelCalls, 1);
      expect(device.disconnectQueues, hasLength(1));
      expect(service.isConnected, isFalse);
      expect(service.reconnectSuppressed, isTrue);
    });
  }

  for (final connection in [false, true]) {
    test(
        '${connection ? 'connection' : 'notification'} listen failure releases acquisition',
        () async {
      if (connection) {
        device.connectionEvents.listenFailure =
            StateError('private listen detail');
      } else {
        device.notifications.listenFailure =
            StateError('private listen detail');
      }
      await expectLater(service.debugConnectDevice(device),
          failsWith(GlassesFailure.bleUnavailable));
      expect(device.connected, isFalse);
      expect(device.connectionEvents.activeListeners, 0);
      expect(device.notifications.activeListeners, 0);
      expect(device.disconnectQueues, hasLength(1));
    });
  }

  test(
      'a stalled subscription cancellation cannot delay other release attempts',
      () async {
    await service.debugConnectDevice(device);
    final release = Completer<void>();
    device.connectionEvents.cancelBlocker = release;
    final closing = service.disconnect();
    await Future<void>.delayed(Duration.zero);
    expect(device.disconnectQueues, hasLength(1));
    expect(device.notifications.cancelCalls, 1);
    release.complete();
    await closing;
    expect(device.connected, isFalse);
  });

  for (final dispose in [false, true]) {
    test(
        'a failed release remains owned for ${dispose ? 'disposal' : 'explicit retry'}',
        () async {
      await service.debugConnectDevice(device);
      device.disconnectFailure = StateError('private disconnect detail');
      device.connectionEvents.failBeforeCancel = true;
      device.connectionEvents.cancelFailure =
          StateError('private cancel detail');
      await expectLater(
          service.disconnect(), failsWith(GlassesFailure.connectionLost));
      expect(device.connected, isTrue);
      expect(device.connectionEvents.activeListeners, 1);
      device.disconnectFailure = null;
      device.connectionEvents.cancelFailure = null;
      if (dispose) {
        service.dispose();
        await service.debugCleanupComplete;
      } else {
        await service.disconnect();
      }
      expect(device.connected, isFalse);
      expect(device.connectionEvents.activeListeners, 0);
      expect(device.notifications.activeListeners, 0);
      expect(device.disconnectQueues, hasLength(2));
      expect(device.writes.map((bytes) => bytes.first), [
        BluetoothCameraService.cmdFlashOff,
      ]);
    });
  }

  test('void dispose closes the real link and owns asynchronous release errors',
      () async {
    await service.debugConnectDevice(device);
    device.connectionEvents.cancelFailure = StateError('private cancel detail');
    device.notifications.cancelFailure = StateError('private notify detail');
    service.dispose();
    await service.debugCleanupComplete;
    expect(device.connected, isFalse);
    expect(device.disconnectQueues, hasLength(1));
    expect(device.connectionEvents.cancelCalls, 1);
    expect(device.notifications.cancelCalls, 1);
    expect(service.isConnected, isFalse);
    expect(service.reconnectSuppressed, isTrue);
    service.dispose();
    await service.debugCleanupComplete;
    expect(device.disconnectQueues, hasLength(1));
  });

  for (final stage in BleAcquisitionStage.values) {
    for (final dispose in [false, true]) {
      test(
          '${dispose ? 'dispose' : 'disconnect'} during pending $stage closes late acquisition',
          () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        device.blockers[stage] = release;
        device.onStage = (current) {
          if (current == stage) entered.complete();
        };
        final acquisition = service.debugConnectDevice(device);
        final failed =
            expectLater(acquisition, failsWith(GlassesFailure.connectionLost));
        await entered.future;
        if (dispose) {
          service.dispose();
        } else {
          await service.disconnect();
        }
        expect(service.isConnected, isFalse);
        release.complete();
        await failed;
        await service.debugCleanupComplete;
        expect(device.connected, isFalse);
        expect(device.disconnectQueues, isNotEmpty);
        expect(device.disconnectQueues, everyElement(isFalse));
        expect(device.connectionEvents.activeListeners, 0);
        expect(device.notifications.activeListeners, 0);
        expect(service.reconnectSuppressed, isTrue);
        expect(device.calls.last, stage);
        expect(device.writes, isEmpty);
      });
    }
  }

  test(
      'successful acquisition subscribes once without sending setup or frame commands',
      () async {
    await service.debugConnectDevice(device);
    expect(service.isConnected, isTrue);
    expect(device.calls, BleAcquisitionStage.values);
    expect(device.connectionEvents.activeListeners, 1);
    expect(device.notifications.activeListeners, 1);
    expect(device.writes, isEmpty);
    await service.disconnect();
    await service.disconnect();
    expect(device.connected, isFalse);
    expect(device.disconnectQueues, hasLength(1));
    expect(device.connectionEvents.cancelCalls, 1);
    expect(device.notifications.cancelCalls, 1);
    expect(device.writes.map((bytes) => bytes.first), [
      BluetoothCameraService.cmdFlashOff,
    ]);
  });

  test(
      'retry cannot reuse a device until the previous late connect has settled',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    device.blockers[BleAcquisitionStage.connect] = release;
    device.onStage = (_) {
      if (!entered.isCompleted) entered.complete();
    };
    final acquisition = service.debugConnectDevice(device);
    final failed =
        expectLater(acquisition, failsWith(GlassesFailure.connectionLost));
    await entered.future;
    await service.disconnect();
    await expectLater(
        service.debugConnectDevice(device), failsWith(GlassesFailure.busy));
    release.complete();
    await failed;
    await service.debugCleanupComplete;
    final closes = device.disconnectQueues.length;
    device.blockers.clear();
    device.onStage = null;
    await service.debugConnectDevice(device);
    await Future<void>.delayed(Duration.zero);
    expect(service.isConnected, isTrue);
    expect(device.connected, isTrue);
    expect(device.disconnectQueues, hasLength(closes));
    expect(device.connectionEvents.activeListeners, 1);
    expect(device.notifications.activeListeners, 1);
    expect(device.writes, isEmpty);
  });

  test('an outstanding teardown cannot close a subsequently acquired device',
      () async {
    await service.debugConnectDevice(device);
    final release = Completer<void>();
    device.disconnectBlocker = release;
    final closing = service.disconnect();
    final next = FakeAcquisitionDevice(id: '02:12:34:56:78:92');
    addTearDown(next.close);
    await expectLater(
        service.debugConnectDevice(next), failsWith(GlassesFailure.busy));
    release.complete();
    await closing;
    await service.debugConnectDevice(next);
    await Future<void>.delayed(Duration.zero);
    expect(service.isConnected, isTrue);
    expect(next.connected, isTrue);
    expect(next.disconnectQueues, isEmpty);
    expect(device.connected, isFalse);
    expect(device.connectionEvents.activeListeners, 0);
    expect(device.notifications.activeListeners, 0);
    service.dispose();
    await service.debugCleanupComplete;
  });

  test(
      'blocked shutdown writes cannot block physical disconnect or leak late errors',
      () async {
    await service.debugConnectDevice(device);
    service.acknowledgmentTimeout = const Duration(milliseconds: 30);
    final release = Completer<void>();
    device.onWrite = (_) async {
      await release.future;
      throw StateError('private late write detail');
    };
    final closing = service.disconnect();
    await Future<void>.delayed(Duration.zero);
    expect(device.connected, isFalse);
    expect(device.disconnectQueues, hasLength(1));
    await closing;
    release.complete();
    await Future<void>.delayed(Duration.zero);
    expect(service.isConnected, isFalse);
    expect(device.writes.map((bytes) => bytes.first), [
      BluetoothCameraService.cmdFlashOff,
    ]);
  });

  test(
      'reconnect rediscovery succeeds without replaying authorization or provisioning',
      () async {
    await service.debugConnectDevice(device);
    device.onWrite =
        (_) => device.feed('${BluetoothCameraService.pairedAck}\n');
    await service.blePair(BluetoothCameraService.blePairingCode);
    expect(service.isPaired, isTrue);
    final reconnected = service.statusStream.firstWhere(
      (status) => status == BluetoothStatus.connected,
    );
    device.dropConnection();
    await reconnected;
    expect(service.isConnected, isTrue);
    expect(service.isPaired, isFalse);
    expect(service.isWifiConfigured, isFalse);
    expect(device.calls.where((s) => s == BleAcquisitionStage.discovery),
        hasLength(2));
    expect(device.connectionEvents.activeListeners, 1);
    expect(device.notifications.activeListeners, 1);
    expect(device.writes, hasLength(1));
  });

  test('a failed reconnect releases its link before another retry', () async {
    await service.debugConnectDevice(device);
    device.failures[BleAcquisitionStage.subscribe] =
        StateError('private retry detail');
    final failed = service.statusStream.firstWhere(
      (status) => status == BluetoothStatus.error,
    );
    device.dropConnection();
    await failed;
    expect(device.connected, isFalse);
    expect(device.connectionEvents.activeListeners, 0);
    expect(device.notifications.activeListeners, 0);
    device.failures.clear();
    final reconnected = service.statusStream.firstWhere(
      (status) => status == BluetoothStatus.connected,
    );
    await reconnected;
    expect(service.isConnected, isTrue);
    expect(device.notifications.activeListeners, 1);
    expect(device.writes, isEmpty);
  });

  for (final dispose in [false, true]) {
    test(
        '${dispose ? 'disposal' : 'manual close'} during reconnect prevents further reconnects',
        () async {
      await service.debugConnectDevice(device);
      final entered = Completer<void>();
      final release = Completer<void>();
      device.blockers[BleAcquisitionStage.connect] = release;
      device.onStage = (stage) {
        if (stage == BleAcquisitionStage.connect) entered.complete();
      };
      device.dropConnection();
      await entered.future;
      if (dispose) {
        service.dispose();
      } else {
        await service.disconnect();
      }
      release.complete();
      // Wait beyond the next backoff; a stale attempt must not reschedule.
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      await service.debugCleanupComplete;
      expect(device.connected, isFalse);
      expect(service.isConnected, isFalse);
      expect(service.reconnectSuppressed, isTrue);
      expect(device.calls.where((s) => s == BleAcquisitionStage.connect),
          hasLength(2));
      expect(device.connectionEvents.activeListeners, 0);
      expect(device.notifications.activeListeners, 0);
      expect(device.writes, isEmpty);
    });
  }

  for (final close in ['observed', 'manual', 'dispose']) {
    test(
        '$close reboot disconnect keeps device evidence separate from teardown',
        () async {
      await service.debugConnectDevice(device);
      device.onWrite = (bytes) {
        if (bytes.first == BluetoothCameraService.cmdBlePair) {
          device.feed('${BluetoothCameraService.pairedAck}\n');
        } else if (bytes.first == BluetoothCameraService.cmdWifiConfigPut) {
          device.feed(
            '${BluetoothCameraService.provisionedAck}\n'
            '\$ESP_MAC:${FakeAcquisitionDevice.testId}\n'
            '\$ESP_NAME:${BluetoothCameraService.expectedHostname}\n',
          );
        } else if (bytes.first == BluetoothCameraService.cmdReboot) {
          device.feed('${BluetoothCameraService.rebootAck}\n');
        }
      };
      await service.blePair(BluetoothCameraService.blePairingCode);
      await service.wifiConfigPut('Synthetic test network', '');
      final reboot = service.reboot();
      final result = close == 'observed'
          ? expectLater(reboot, completes)
          : expectLater(reboot, failsWith(GlassesFailure.connectionLost));
      await Future<void>.delayed(Duration.zero);
      if (close == 'observed') {
        device.dropConnection();
      } else if (close == 'manual') {
        await service.disconnect();
      } else {
        service.dispose();
      }
      await result;
      await service.debugCleanupComplete;
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(service.isConnected, isFalse);
      expect(device.connected, isFalse);
      expect(service.reconnectSuppressed, isTrue);
      expect(device.calls.where((s) => s == BleAcquisitionStage.connect),
          hasLength(1));
      expect(device.writes.map((bytes) => bytes.first), [
        BluetoothCameraService.cmdBlePair,
        BluetoothCameraService.cmdWifiConfigPut,
        BluetoothCameraService.cmdReboot,
      ]);
    });
  }

  for (final connection in [false, true]) {
    test(
        '${connection ? 'connection' : 'notification'} stream error closes safely without unhandled errors',
        () async {
      await service.debugConnectDevice(device);
      if (connection) {
        device.connectionEvents.addError(StateError('private stream detail'));
      } else {
        device.notifications.addError(StateError('private stream detail'));
      }
      await service.debugCleanupComplete;
      expect(service.isConnected, isFalse);
      expect(device.connected, isFalse);
      expect(device.connectionEvents.activeListeners, 0);
      expect(device.notifications.activeListeners, 0);
    });
  }
}
