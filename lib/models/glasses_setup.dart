/// Commissioning stages advance only after fresh device evidence.
enum GlassesSetupStage {
  idle,
  connecting,
  pairing,
  provisioning,
  rebooting,
  awaitingIp,
  waitingForFrame,
  ready,
  failed,
}

enum GlassesFailure {
  bleUnavailable,
  bleWriteFailed,
  acknowledgmentTimeout,
  invalidCredentials,
  invalidIdentity,
  pairingRequired,
  busy,
  connectionLost,
  rebootTimeout,
  invalidIp,
  udpUnavailable,
  udpTimeout,
  udpStalled,
  unsupportedControl,
}

/// Transport failures carry a stable code, never credentials or raw errors.
class GlassesException implements Exception {
  final GlassesFailure code;
  const GlassesException(this.code);

  @override
  String toString() => 'GlassesException(${code.name})';
}
