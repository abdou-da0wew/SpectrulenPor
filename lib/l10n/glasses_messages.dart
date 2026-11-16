import '../models/glasses_setup.dart';
import 'app_localizations.dart';

extension GlassesMessages on AppLocalizations {
  String setupProgress(GlassesSetupStage stage) => switch (stage) {
        GlassesSetupStage.idle => setupIdle,
        GlassesSetupStage.connecting => scanningGlasses,
        GlassesSetupStage.pairing => setupPairing,
        GlassesSetupStage.provisioning => setupProvisioning,
        GlassesSetupStage.rebooting => setupRebooting,
        GlassesSetupStage.awaitingIp => setupAwaitingIp,
        GlassesSetupStage.waitingForFrame => setupWaitingFrame,
        GlassesSetupStage.ready => wifiConnected,
        GlassesSetupStage.failed => setupFailed,
      };

  String setupFailure(GlassesFailure failure) => switch (failure) {
        GlassesFailure.bleUnavailable => setupErrorBleUnavailable,
        GlassesFailure.bleWriteFailed => setupErrorBleWrite,
        GlassesFailure.acknowledgmentTimeout => setupErrorAckTimeout,
        GlassesFailure.invalidCredentials => setupErrorCredentials,
        GlassesFailure.invalidIdentity => setupErrorIdentity,
        GlassesFailure.pairingRequired => setupErrorPairing,
        GlassesFailure.busy => setupErrorBusy,
        GlassesFailure.connectionLost => setupErrorConnectionLost,
        GlassesFailure.rebootTimeout => setupErrorReboot,
        GlassesFailure.invalidIp => setupErrorIp,
        GlassesFailure.udpUnavailable => setupErrorUdp,
        GlassesFailure.udpTimeout => setupErrorUdpTimeout,
        GlassesFailure.udpStalled => setupErrorUdpStalled,
        GlassesFailure.unsupportedControl => setupErrorUnsupported,
      };
}
