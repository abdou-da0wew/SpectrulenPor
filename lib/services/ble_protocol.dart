/// BLE GATT contract for ESP32-CAM (mirrors firmware config.h).
///
/// TX (notify): ffe1  | RX (write with response): ffe2  | Service: ffe0
/// Command bytes: 0x00 pause, 0x01 stream on, 0x02 single frame, 0x03 flash on,
/// 0x04 flash off, 0x05 restart, 0x06 shutdown, 0x07 wifi config put,
/// 0x08 wifi config get, 0x09 connection status, 0x0A pair, 0x0B reboot.
abstract class BleProtocol {
  /// TX notify characteristic UUID.
  static const String txCharUuid = '0000ffe1-0000-1000-8000-00805f9b34fb';
  /// RX write characteristic UUID.
  static const String rxCharUuid = '0000ffe2-0000-1000-8000-00805f9b34fb';
  /// GATT service UUID.
  static const String serviceUuid = '0000ffe0-0000-1000-8000-00805f9b34fb';

  /// Command bytes (mirrored in firmware config.h).
  static const int cmdStreamOn = 0x01;
  static const int cmdStreamOff = 0x00;
  static const int cmdSingleFrame = 0x02;
  static const int cmdFlashOn = 0x03;
  static const int cmdFlashOff = 0x04;
  static const int cmdRestart = 0x05;
  static const int cmdShutdown = 0x06;
  static const int cmdWifiConfigPut = 0x07;
  static const int cmdWifiConfigGet = 0x08;
  static const int cmdConnectionStatus = 0x09;
  static const int cmdBlePair = 0x0A;
  static const int cmdReboot = 0x0B;

  /// Pairing code required before WiFi config can be sent over BLE.
  static const String blePairingCode = '11111';

  /// ESP32-CAM hardware constants.
  static const String expectedHostname = 'spectrulenpor-esp32';

  /// Safety cap for BLE JPEG reassembly if an EOI packet is dropped.
  static const int maxFrameBytes = 512 * 1024;

  /// Auto-reconnect policy: exponential backoff 1,2,4,8,16,16 s, then give up.
  static const int maxReconnectAttempts = 6;
  static const Duration connectTimeout = Duration(seconds: 15);
  static const int requestedMtu = 517;

  static const int maxTextBytes = 1024;
  static const int maxSsidBytes = 32;
  static const int minPassphraseBytes = 8;
  static const int maxPassphraseBytes = 63;
  static const int pskBytes = 64;

  static const String pairedAck = r'$CMD:paired';
  static const String provisionedAck = r'$CMD:wifi_config_received';
  static const String rebootAck = r'$CMD:reboot';
}
