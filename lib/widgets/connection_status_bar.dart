import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/recognition_state.dart';
import '../utils/app_theme.dart' as palette;

/// Header pill showing the BLE connection state of the glasses,
/// plus a connect / disconnect action.
class ConnectionStatusBar extends StatelessWidget {
  final BluetoothStatus status;
  final String? deviceName;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  const ConnectionStatusBar({
    super.key,
    required this.status,
    this.deviceName,
    required this.onConnect,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final icon = _iconFor(status);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        gradient: status == BluetoothStatus.connected
            ? palette.AppColors.headerGradient
            : null,
        color: status == BluetoothStatus.connected
            ? null
            : palette.AppColors.dustGrey,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              deviceName == null
                  ? _label(context, status)
                  : '${_label(context, status)} · $deviceName',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 13.5,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          if (status == BluetoothStatus.scanning ||
              status == BluetoothStatus.connecting)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2,
              ),
            )
          else if (status == BluetoothStatus.connected)
            TextButton.icon(
              onPressed: onDisconnect,
              icon: const Icon(Icons.link_off, size: 16, color: Colors.white),
              label: Text(AppLocalizations.of(context).disconnect,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 12.5)),
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            )
          else
            TextButton.icon(
              onPressed: onConnect,
              icon: const Icon(Icons.bluetooth_searching,
                  size: 16, color: Colors.white),
              label: Text(AppLocalizations.of(context).connectGlasses,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 12.5)),
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: Colors.white,
              ),
            ),
        ],
      ),
    );
  }

  IconData _iconFor(BluetoothStatus s) {
    switch (s) {
      case BluetoothStatus.disconnected:
        return Icons.bluetooth_disabled;
      case BluetoothStatus.scanning:
        return Icons.bluetooth_searching;
      case BluetoothStatus.connecting:
        return Icons.bluetooth;
      case BluetoothStatus.connected:
        return Icons.bluetooth_connected;
      case BluetoothStatus.error:
        return Icons.error_outline;
    }
  }
}
