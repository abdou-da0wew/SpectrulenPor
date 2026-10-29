/// Connection state of the BLE camera (shared by the service, the central
/// state and the UI widgets).
enum BluetoothStatus {
  disconnected,
  scanning,
  connecting,
  connected,
  permissionDenied,
  adapterOff,
  error,
}
