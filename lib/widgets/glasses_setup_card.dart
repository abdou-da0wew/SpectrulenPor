import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../l10n/glasses_messages.dart';
import '../models/recognition_state.dart';
import '../services/bluetooth_camera_service.dart';
import '../services/wifi_udp_video_service.dart';
import '../utils/app_icons.dart';

/// Setup inputs are ephemeral; only confirmed device identity is remembered.
class GlassesSetupCard extends StatefulWidget {
  const GlassesSetupCard({super.key});

  @override
  State<GlassesSetupCard> createState() => _GlassesSetupCardState();
}

class _GlassesSetupCardState extends State<GlassesSetupCard> {
  static const double maxPanelHeight = 220;
  final _ssid = TextEditingController();
  final _password = TextEditingController();
  final _ip = TextEditingController();

  @override
  void initState() {
    super.initState();
    final state = context.read<RecognitionState>();
    _ssid.text = state.wifiSsid;
    _ip.text = state.wifiIp;
  }

  @override
  void dispose() {
    _ssid.dispose();
    _password.dispose();
    _ip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RecognitionState>();
    final l = AppLocalizations.of(context);
    final failure = state.glassesFailure;
    final identity = state.bluetooth;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: maxPanelHeight),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l.wifiConfigTitle,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Semantics(
                liveRegion: true,
                child: Text(
                  state.udpVideo.isActive &&
                          !state.udpVideo.isStreaming &&
                          state.wifiConnected
                      ? l.videoPaused
                      : l.setupProgress(state.setupStage),
                ),
              ),
              if (state.setupBusy) const LinearProgressIndicator(),
              if (failure != null) ...[
                const SizedBox(height: 6),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    l.setupFailure(failure),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              if (state.configurationUncertain) Text(l.setupRecoveryHint),
              if (identity.espMacAddress != null &&
                  identity.espHostname != null)
                SelectableText(
                  l.setupIdentity(
                    identity.espHostname!,
                    identity.espMacAddress!,
                  ),
                ),
              if (!state.credentialsSaved && !state.configurationUncertain) ...[
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('glasses-ssid'),
                  controller: _ssid,
                  enabled: !state.setupBusy,
                  decoration: InputDecoration(
                    labelText: l.wifiSsidLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('glasses-password'),
                  controller: _password,
                  enabled: !state.setupBusy,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: l.wifiPasswordLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                Text(
                  l.setupCredentialsHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                FilledButton.icon(
                  key: const ValueKey('glasses-setup-start'),
                  onPressed: state.canProvision &&
                          BluetoothCameraService.validCredentials(
                            _ssid.text,
                            _password.text,
                          )
                      ? () async {
                          final password = _password.text;
                          _password.clear();
                          setState(() {});
                          await state.setWifiConfig(_ssid.text, password);
                        }
                      : null,
                  icon: const Icon(AppIcons.saveRounded),
                  label: Text(l.wifiSaveConnect),
                ),
              ],
              if (state.credentialsSaved &&
                  identity.isWifiConfigured &&
                  identity.isConnected &&
                  !state.setupBusy)
                OutlinedButton(
                  key: const ValueKey('glasses-reboot-retry'),
                  onPressed: state.rebootProvisionedGlasses,
                  child: Text(l.setupRetryReboot),
                ),
              const SizedBox(height: 8),
              Text(
                l.setupManualIpHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              TextField(
                key: const ValueKey('glasses-ip'),
                controller: _ip,
                enabled: !state.setupBusy && !state.udpVideo.isActive,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: l.glassesIpLabel,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              FilledButton.icon(
                key: const ValueKey('glasses-udp-start'),
                onPressed: !state.setupBusy &&
                        !state.udpVideo.isActive &&
                        WifiUdpVideoService.parsePeerAddress(_ip.text.trim()) !=
                            null
                    ? () => state.startUdpVideo(_ip.text.trim())
                    : null,
                icon: const Icon(AppIcons.wifiRounded),
                label: Text(l.startUdpVideo),
              ),
              if (state.udpVideo.isActive)
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      key: const ValueKey('glasses-video-pause-resume'),
                      onPressed: state.setupBusy
                          ? null
                          : state.udpVideo.isStreaming
                              ? state.pauseGlassesStream
                              : state.resumeGlassesStream,
                      child: Text(
                        state.udpVideo.isStreaming
                            ? l.pauseVideo
                            : l.resumeVideo,
                      ),
                    ),
                    OutlinedButton(
                      key: const ValueKey('glasses-video-single-frame'),
                      onPressed:
                          state.setupBusy ? null : state.requestGlassesFrame,
                      child: Text(l.requestOneFrame),
                    ),
                    OutlinedButton(
                      key: const ValueKey('glasses-video-stop'),
                      onPressed: state.stopUdpVideo,
                      child: Text(l.stopVideo),
                    ),
                  ],
                ),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    key: const ValueKey('glasses-ble-status'),
                    onPressed: state.canUseBleControls
                        ? state.requestWifiStatus
                        : null,
                    child: Text(l.refreshStatus),
                  ),
                  OutlinedButton(
                    key: const ValueKey('glasses-ble-restart'),
                    onPressed:
                        state.canUseBleControls ? state.restartGlasses : null,
                    child: Text(l.restartEsp),
                  ),
                  OutlinedButton(
                    key: const ValueKey('glasses-ble-standby'),
                    onPressed:
                        state.canUseBleControls ? state.shutdownGlasses : null,
                    child: Text(l.shutdownGlasses),
                  ),
                ],
              ),
              if (!state.canUseBleControls)
                Text(
                  l.wifiOnlyControlsUnavailable,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
