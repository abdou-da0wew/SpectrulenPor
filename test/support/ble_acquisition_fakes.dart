import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:smart_glass_app/services/bluetooth_camera_service.dart';

enum BleAcquisitionStage { connect, mtu, discovery, subscribe }

/// Only the plugin boundary is stubbed. No platform, radio or network is used.
class FakeAcquisitionDevice extends BluetoothDevice {
  static const testId = '02:12:34:56:78:90';
  static const requestedMtu = 517;
  final connectionEvents = TrackedBleStream<BluetoothConnectionState>();
  final notifications = TrackedBleStream<List<int>>();
  final calls = <BleAcquisitionStage>[];
  final writes = <List<int>>[];
  final disconnectQueues = <bool>[];
  final blockers = <BleAcquisitionStage, Completer<void>>{};
  final failures = <BleAcquisitionStage, Object>{};
  FutureOr<void> Function(BleAcquisitionStage)? onStage;
  FutureOr<void> Function(List<int>)? onWrite;
  Completer<void>? disconnectBlocker;
  Object? disconnectFailure;
  bool connected = false;
  bool missingService = false;
  bool missingTx = false;
  bool missingRx = false;
  late final tx = FakeAcquisitionCharacteristic(this, isTx: true);
  late final rx = FakeAcquisitionCharacteristic(this, isTx: false);

  FakeAcquisitionDevice({String id = testId})
      : super(remoteId: DeviceIdentifier(id));

  @override
  String get platformName => 'SpectruLenPor test device';

  @override
  bool get isConnected => connected;

  @override
  Stream<BluetoothConnectionState> get connectionState => connectionEvents;

  Future<void> stage(BleAcquisitionStage stage) async {
    calls.add(stage);
    await onStage?.call(stage);
    await blockers[stage]?.future;
    final failure = failures[stage];
    if (failure != null) throw failure;
  }

  @override
  Future<void> connect({
    Duration timeout = const Duration(seconds: 35),
    int? mtu = 512,
    bool autoConnect = false,
  }) async {
    await stage(BleAcquisitionStage.connect);
    connected = true;
    connectionEvents.add(BluetoothConnectionState.connected);
  }

  @override
  Future<int> requestMtu(
    int desiredMtu, {
    double predelay = 0.35,
    int timeout = 15,
  }) async {
    await stage(BleAcquisitionStage.mtu);
    return desiredMtu;
  }

  @override
  Future<List<BluetoothService>> discoverServices({
    bool subscribeToServicesChanged = true,
    int timeout = 15,
  }) async {
    await stage(BleAcquisitionStage.discovery);
    return missingService
        ? []
        : [
            FakeAcquisitionService([
              if (!missingTx) tx,
              if (!missingRx) rx,
            ]),
          ];
  }

  @override
  Future<void> disconnect({
    int timeout = 35,
    bool queue = true,
    int androidDelay = 2000,
  }) async {
    disconnectQueues.add(queue);
    await disconnectBlocker?.future;
    final failure = disconnectFailure;
    if (failure != null) throw failure;
    dropConnection();
  }

  void dropConnection() {
    connected = false;
    connectionEvents.add(BluetoothConnectionState.disconnected);
  }

  void feed(String text) => notifications.add(utf8.encode(text));

  Future<void> close() async {
    connected = false;
    await connectionEvents.close();
    await notifications.close();
  }
}

class FakeAcquisitionService implements BluetoothService {
  @override
  final List<BluetoothCharacteristic> characteristics;

  FakeAcquisitionService(this.characteristics);

  @override
  Guid get uuid => Guid(BluetoothCameraService.serviceUuid);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeAcquisitionCharacteristic extends BluetoothCharacteristic {
  final FakeAcquisitionDevice owner;
  final bool isTx;

  FakeAcquisitionCharacteristic(this.owner, {required this.isTx})
      : super(
          remoteId: owner.remoteId,
          serviceUuid: Guid(BluetoothCameraService.serviceUuid),
          characteristicUuid: Guid(isTx
              ? BluetoothCameraService.txCharUuid
              : BluetoothCameraService.rxCharUuid),
        );

  @override
  Stream<List<int>> get onValueReceived => owner.notifications;

  @override
  Future<bool> setNotifyValue(
    bool notify, {
    int timeout = 15,
    bool forceIndications = false,
  }) async {
    await owner.stage(BleAcquisitionStage.subscribe);
    return true;
  }

  @override
  Future<void> write(
    List<int> value, {
    bool withoutResponse = false,
    bool allowLongWrite = false,
    int timeout = 15,
  }) async {
    owner.writes.add(List<int>.from(value));
    await owner.onWrite?.call(value);
  }
}

/// Cancellation can fail or stall without preventing assertions on other leases.
class TrackedBleStream<T> extends Stream<T> {
  final _controller = StreamController<T>.broadcast(sync: true);
  int activeListeners = 0;
  int cancelCalls = 0;
  Object? cancelFailure;
  bool failBeforeCancel = false;
  Object? listenFailure;
  void Function()? onListen;
  Completer<void>? cancelBlocker;

  void add(T event) => _controller.add(event);
  void addError(Object error) => _controller.addError(error);
  Future<void> close() => _controller.close();

  @override
  StreamSubscription<T> listen(
    void Function(T)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final failure = listenFailure;
    if (failure != null) throw failure;
    ++activeListeners;
    final subscription = _TrackedBleSubscription(
      _controller.stream.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      ),
      this,
    );
    onListen?.call();
    return subscription;
  }
}

class _TrackedBleSubscription<T> implements StreamSubscription<T> {
  final StreamSubscription<T> _inner;
  final TrackedBleStream<T> _owner;
  bool _cancelled = false;

  _TrackedBleSubscription(this._inner, this._owner);

  @override
  Future<void> cancel() async {
    if (_cancelled) return;
    if (_owner.failBeforeCancel && _owner.cancelFailure != null) {
      ++_owner.cancelCalls;
      throw _owner.cancelFailure!;
    }
    _cancelled = true;
    ++_owner.cancelCalls;
    --_owner.activeListeners;
    await _inner.cancel();
    await _owner.cancelBlocker?.future;
    final failure = _owner.cancelFailure;
    if (failure != null) throw failure;
  }

  @override
  void onData(void Function(T)? handleData) => _inner.onData(handleData);
  @override
  void onError(Function? handleError) => _inner.onError(handleError);
  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);
  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);
  @override
  void resume() => _inner.resume();
  @override
  bool get isPaused => _inner.isPaused;
  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture(futureValue);
}
