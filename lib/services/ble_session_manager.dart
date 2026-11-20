import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/glasses_setup.dart';
import 'ble_protocol.dart';

/// Represents one BLE connection session. Retained for the lifetime of the
/// connection; replies/frame chunks bind to the session that submitted them.
class _BleSession {
  final BluetoothDevice device;
  final int generation;

  StreamSubscription<BluetoothConnectionState>? connection;
  StreamSubscription<List<int>>? notification;
  BluetoothCharacteristic? rxChar;

  bool connectPending = false;
  bool closedDuringConnect = false;
  bool deviceReleased = false;
  Future<bool>? release;
  Future<bool>? lateRelease;
  Future<bool>? deviceRelease;

  _BleSession(this.device, this.generation);
}

/// Callback invoked when a session has been fully established (connected,
/// MTU negotiated, services discovered, notifications subscribed). The
/// service uses this to mark the session ready.
typedef SessionEstablished = Future<void> Function();

/// Callback invoked when the current session is lost (disconnected, stream
/// error, or connect failure). The service uses this to update status and
/// schedule reconnection.
typedef SessionLost = void Function({required bool observed});
typedef ReconnectFailed = void Function();

/// Callback invoked when a BLE notification payload is received. The service
/// uses this to reassemble JPEG frames and handle text telemetry.
typedef NotificationReceived = void Function(List<int> bytes);

/// Manages BLE session lifecycle: connection, replacement, cleanup, retry.
///
/// Failed releases retain ownership for explicit retry admission; only the
/// newest release pass may retire ownership. All raw BLE resource handling
/// (connect, MTU, service discovery, notification subscription, cancel,
/// disconnect) lives here. Service-specific state (paired, configured,
/// status streams) is owned by [BluetoothCameraService].
class BleSessionManager {
  BleSessionManager({
    required this.onSessionEstablished,
    required this.onSessionLost,
    required this.onNotification,
    this.onReconnectFailed,
  });

  final SessionEstablished onSessionEstablished;
  final SessionLost onSessionLost;
  final NotificationReceived onNotification;
  final ReconnectFailed? onReconnectFailed;

  _BleSession? _session;
  final Set<_BleSession> _retiredSessions = {};
  int _releasesPending = 0;
  bool _reconnectInFlight = false;
  Timer? _reconnectTimer;
  bool _userDisconnect = false;
  int _reconnectAttempts = 0;
  int _sessionGeneration = 0;
  BluetoothDevice? _reconnectDevice;

  Future<void> _cleanupComplete = Future<void>.value();

  /// Whether a session is currently active (connected or connecting).
  bool get hasSession => _session != null;

  /// The device of the current session, for reconnection.
  BluetoothDevice? get device => _session?.device;

  /// The RX characteristic of the current session, for writing commands.
  BluetoothCharacteristic? get rxChar => _session?.rxChar;

  /// Whether a session is currently connected.
  bool get isConnected => _session != null && _session!.device.isConnected;

  /// Whether automatic reconnection is suppressed (user-initiated disconnect).
  bool get reconnectSuppressed => _userDisconnect;

  /// Suppress automatic reconnect after a device reboot or explicit handoff.
  void suppressReconnect() {
    _userDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectDevice = null;
  }

  /// Re-enable reconnection only for a fresh user-initiated scan/connect.
  void prepareForUserConnect() {
    _userDisconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// Whether a reconnection attempt is currently in flight.
  bool get reconnectInFlight => _reconnectInFlight;

  /// Number of releases currently pending.
  int get releasesPending => _releasesPending;

  /// Completes when all tracked releases have finished.
  Future<void> get cleanupComplete => _cleanupComplete;

  /// Connect to [device] and establish a full BLE session (connect, MTU,
  /// service discovery, notification subscription). Calls [onSessionEstablished]
  /// when the session is ready, or [onSessionLost] on failure.
  Future<void> connect(BluetoothDevice device) async {
    final previousGeneration = _sessionGeneration;
    await _cleanupComplete;
    if (_userDisconnect || previousGeneration != _sessionGeneration) {
      throw const GlassesException(GlassesFailure.connectionLost);
    }
    if (!await releaseRetiredSessions()) {
      throw const GlassesException(GlassesFailure.connectionLost);
    }
    if (_userDisconnect || previousGeneration != _sessionGeneration) {
      throw const GlassesException(GlassesFailure.connectionLost);
    }

    _clearSession();
    final session = _BleSession(device, _sessionGeneration);
    _session = session;
    _reconnectDevice = null;

    try {
      session.connectPending = true;
      await device.connect(
        timeout: BleProtocol.connectTimeout,
        mtu: null,
      );
      _ensureCurrent(session);

      // Attach each lease before checking session identity. Some BLE adapters
      // synchronously emit a disconnect while listen() is being established.
      final connection = device.connectionState.listen(
        (state) {
          if (state == BluetoothConnectionState.disconnected) {
            _handleObservedDisconnect(session);
          }
        },
        onError: (Object _) => _handleObservedDisconnect(session),
      );
      session.connection = connection;
      _ensureCurrent(session);

      await device.requestMtu(BleProtocol.requestedMtu);
      _ensureCurrent(session);

      final services = await device.discoverServices();
      _ensureCurrent(session);
      final svc = services.firstWhere(
        (s) => s.uuid.str128 == BleProtocol.serviceUuid,
        orElse: () =>
            throw const GlassesException(GlassesFailure.bleUnavailable),
      );
      final tx = svc.characteristics.firstWhere(
        (c) => c.uuid.str128 == BleProtocol.txCharUuid,
        orElse: () =>
            throw const GlassesException(GlassesFailure.bleUnavailable),
      );
      final rx = svc.characteristics.firstWhere(
        (c) => c.uuid.str128 == BleProtocol.rxCharUuid,
        orElse: () =>
            throw const GlassesException(GlassesFailure.bleUnavailable),
      );

      // Unlike lastValueStream this never replays a cached ACK on reconnect.
      final notification = tx.onValueReceived.listen(
        (bytes) {
          if (identical(_session, session)) onNotification(bytes);
        },
        onError: (Object _) => _handleObservedDisconnect(session),
      );
      session.notification = notification;
      _ensureCurrent(session);

      await tx.setNotifyValue(true);
      _ensureCurrent(session);
      session.rxChar = rx;

      await onSessionEstablished();
      _ensureCurrent(session);
      _reconnectAttempts = 0;
    } catch (error) {
      // This catch means the acquisition future has settled. Only a separate
      // disconnect racing an outstanding connect may require late release.
      session.connectPending = false;
      if (identical(_session, session)) {
        _session = null;
        _reconnectDevice = session.device;
        _clearSession();
        onSessionLost(observed: false);
      }
      await _releaseSession(session);
      // Cancellation can finish before connect returns. A late successful
      // connect is still this lease's resource, never a new session's link.
      if (session.closedDuringConnect && device.isConnected) {
        await _releaseLateConnection(session);
      }
      await _cleanupComplete;
      if (error is GlassesException) rethrow;
      throw const GlassesException(GlassesFailure.bleUnavailable);
    } finally {
      session.connectPending = false;
    }
  }

  /// Release all retired sessions and return whether all succeeded.
  /// Used by the service before starting a new acquisition.
  Future<bool> releaseRetiredSessions() => _releaseRetiredSessions();

  /// Disconnect the current session. When [user] is true, automatic
  /// reconnection is suppressed.
  Future<void> disconnect({bool user = false}) async {
    _userDisconnect = user;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final session = _session;
    _session = null;
    _reconnectDevice = user ? null : session?.device;
    _clearSession();
    if (session != null) {
      onSessionLost(observed: false);
      if (!user) _scheduleReconnect();
      if (!await _releaseSession(session)) {
        throw const GlassesException(GlassesFailure.connectionLost);
      }
    } else {
      if (user) _reconnectDevice = null;
      if (!await _releaseRetiredSessions()) {
        throw const GlassesException(GlassesFailure.connectionLost);
      }
    }
  }

  /// Reconcile a physical disconnect observed by a platform stream.
  void debugDisconnectCurrentSession() {
    final session = _session;
    if (session != null) _handleObservedDisconnect(session);
  }

  /// Dispose the manager, suppressing reconnection and releasing all
  /// resources.
  void dispose() {
    _userDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectInFlight = false;
    final session = _session;
    _session = null;
    _reconnectDevice = null;
    _clearSession();
    if (session != null) {
      unawaited(_releaseSession(session));
    }
    _releaseAllRetired();
  }

  /// Release all retired sessions immediately.
  void _releaseAllRetired() {
    for (final session in _retiredSessions.toList()) {
      unawaited(_releaseSession(session));
    }
  }

  void _clearSession() {
    _sessionGeneration++;
  }

  void _ensureCurrent(_BleSession session) {
    if (_userDisconnect ||
        !identical(_session, session) ||
        session.generation != _sessionGeneration ||
        !session.device.isConnected) {
      throw const GlassesException(GlassesFailure.connectionLost);
    }
  }

  void _handleObservedDisconnect(_BleSession session) {
    if (!identical(_session, session)) return;
    _session = null;
    _reconnectDevice = session.device;
    _clearSession();
    onSessionLost(observed: true);
    unawaited(_releaseSession(session));
    if (!_userDisconnect) _scheduleReconnect();
  }

  Future<bool> _releaseDevice(_BleSession session) {
    if (session.deviceReleased) return Future<bool>.value(true);
    final pending = session.deviceRelease;
    if (pending != null) return pending;
    late final Future<bool> release;
    release = _attemptRelease(
      () => session.device.disconnect(queue: false),
    ).then((released) {
      if (released) {
        session.deviceReleased = true;
      } else if (identical(session.deviceRelease, release)) {
        session.deviceRelease = null;
      }
      return released;
    });
    session.deviceRelease = release;
    return release;
  }

  void _scheduleReconnect() {
    if (_reconnectInFlight || _userDisconnect || _reconnectDevice == null) {
      return;
    }
    if (_reconnectAttempts >= BleProtocol.maxReconnectAttempts) {
      debugPrint(
        '[BLE] gave up auto-reconnect after '
        '$_reconnectAttempts attempts.',
      );
      return;
    }
    final generation = _sessionGeneration;
    final device = _reconnectDevice;
    _reconnectAttempts++;
    // 1, 2, 4, 8, 16, 16 s backoff steps.
    final step = (_reconnectAttempts - 1).clamp(0, 4);
    final delay = Duration(seconds: 1 << step);
    debugPrint(
      '[BLE] auto-reconnect attempt $_reconnectAttempts/'
      '${BleProtocol.maxReconnectAttempts} in ${delay.inSeconds}s…',
    );
    _reconnectTimer = Timer(delay, () async {
      if (device == null ||
          _userDisconnect ||
          generation != _sessionGeneration) {
        return;
      }
      _reconnectInFlight = true;
      var retry = false;
      try {
        await connect(device);
        _reconnectAttempts = 0;
        debugPrint('[BLE] auto-reconnected.');
      } catch (e) {
        if (_userDisconnect) return;
        debugPrint('[BLE] reconnect attempt failed: $e');
        onReconnectFailed?.call();
        retry = true;
      } finally {
        _reconnectInFlight = false;
        if (retry) _scheduleReconnect();
      }
    });
  }

  /// Attempt a release independently of other releases.
  Future<bool> _attemptRelease(Future<void> Function() release) async {
    try {
      await release();
      return true;
    } catch (_) {
      debugPrint('[BLE] resource release failed: connectionLost');
      return false;
    }
  }

  /// Track a release so its pending state can be observed independently.
  Future<bool> _trackRelease(Future<bool> release) {
    ++_releasesPending;
    final tracked = release.whenComplete(() {
      --_releasesPending;
    });
    _cleanupComplete = Future.wait([
      _cleanupComplete,
      tracked.then<void>((_) {}),
    ]).then<void>((_) {});
    return tracked;
  }

  Future<bool> _releaseRetiredSessions() async {
    final results = await Future.wait(
      _retiredSessions.toList().map(_releaseSession),
    );
    return results.every((released) => released);
  }

  Future<bool> _releaseSession(_BleSession session) {
    final previousRelease = session.release;
    if (previousRelease != null &&
        session.connection == null &&
        session.notification == null) {
      return previousRelease;
    }
    if (previousRelease == null) {
      session.closedDuringConnect = session.connectPending;
    }
    _retiredSessions.add(session);
    final connection = session.connection;
    final notification = session.notification;
    session.connection = null;
    session.notification = null;
    // Start each release independently, even when another cancellation stalls.
    late final Future<bool> release;
    release = _trackRelease(Future.wait([
      _attemptRelease(() async {
        await connection?.cancel();
      }).then((released) {
        if (!released) session.connection ??= connection;
        return released;
      }),
      _attemptRelease(() async {
        await notification?.cancel();
      }).then((released) {
        if (!released) session.notification ??= notification;
        return released;
      }),
      // listen() may deliver a synchronous event before returning its lease.
      // A second pass cancels that late subscription, not the device again.
      _releaseDevice(session),
    ]).then((results) => results.every((released) => released)));
    session.release = release;
    return release.then((released) {
      // A late subscription can start a newer pass before this one finishes.
      // Only the current pass may retire ownership or make it retryable.
      if (identical(session.release, release)) {
        if (released) {
          _retiredSessions.remove(session);
        } else {
          // Failed releases retain their owner for explicit retry admission;
          // never replay setup/control writes.
          session.release = null;
        }
      }
      return released;
    });
  }

  /// Releases a session late (after it has been replaced by a newer session).
  /// The late release does not retire ownership of the newer session.
  Future<bool> _releaseLateConnection(_BleSession session) {
    if (session.lateRelease != null) return session.lateRelease!;
    session.release = null;
    session.deviceReleased = false;
    session.deviceRelease = null;
    return session.lateRelease = _releaseSession(session);
  }
}
