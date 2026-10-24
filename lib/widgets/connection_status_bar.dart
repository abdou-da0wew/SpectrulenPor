import 'package:flutter/material.dart';

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
    final theme = Theme.of(context);
    final (label, color, icon) = _map(status);

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
              deviceName == null ? label : '$label · $deviceName',
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
              label: const Text('Disconnect',
                  style: TextStyle(color: Colors.white, fontSize: 12.5)),
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
              label: const Text('Connect glasses',
                  style: TextStyle(color: Colors.white, fontSize: 12.5)),
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

  (String, Color, IconData) _map(BluetoothStatus s) {
    switch (s) {
      case BluetoothStatus.disconnected:
        return ('Glasses not connected', palette.AppColors.inkSoft, Icons.bluetooth_disabled);
      case BluetoothStatus.scanning:
        return ('Scanning for glasses…', palette.AppColors.dustyMauve, Icons.bluetooth_searching);
      case BluetoothStatus.connecting:
        return ('Connecting…', palette.AppColors.dustyMauve, Icons.bluetooth);
      case BluetoothStatus.connected:
        return ('Connected', palette.AppColors.dustyLavender, Icons.bluetooth_connected);
      case BluetoothStatus.error:
        return ('Bluetooth error', palette.AppColors.danger, Icons.error_outline);
    }
  }
}
