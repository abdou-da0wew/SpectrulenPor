# SpectruLenPor Lab

A native GNOME diagnostics and commissioning console for the SpectruLenPor ESP32-CAM firmware.

## Features

- BLE discovery and GATT connection using BlueZ, with the firmware's FFE0 service, FFE1 notifications and FFE2 write characteristic.
- The mobile commissioning flow: application pairing code `11111`, Wi-Fi SSID/password provisioning, reboot acknowledgement, then UDP peer discovery.
- Native GTK 4 + Libadwaita UI with overview, commissioning, live video, sensor and diagnostics pages.
- UDP V2 receive path on port 8888: 24-byte little-endian header, 1448-byte JPEG payload, XOR FEC recovery, command/status channel and broadcast peer registration.
- JPEG live preview, receiver FPS, throughput, packet counts, incomplete frames, recovered fragments, jitter and frame-assembly timings.
- ESP32-reported RSSI, Wi-Fi channel, camera profile/readiness, internal heap, minimum heap, PSRAM and sender frame/error counters.
- Full AS7265x spectral snapshot: 18 raw channels from 410 nm to 940 nm plus temperature readings from the AS72653, AS72652 and AS72651 dies. Values remain raw ADC counts, not calibrated irradiance.
- Optional USB UART log monitoring at 115200 baud, with sender-side FPS/retry/backoff telemetry.

The spectral sensor values are read from the three AS7265x dies. The app intentionally does not convert raw counts into lux or calibrated optical power.

## System requirements

Ubuntu / GNOME with:
- Python 3.12+ (the system Python that can import PyGObject)
- GTK 4
- Libadwaita 1
- PyGObject / Gio D-Bus
- BlueZ
- NetworkManager / `nmcli`
- pyserial (only for the UART panel)

On Ubuntu, the matching system packages are typically:

```bash
sudo apt install python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 gir1.2-gdkpixbuf-2.0 bluez network-manager python3-serial
```

## Run and install

Run directly from the repository root:

```bash
./desktop/run.sh
```

Install a launcher into GNOME Activities / the application grid:

```bash
./desktop/install.sh
```

Remove only the launcher later with `./desktop/uninstall.sh`. The project files remain untouched.

The app does not need root. For serial access, ensure the user is in the `dialout` group and sign in again:

```bash
sudo usermod -aG dialout "$USER"
```

## Commissioning sequence

1. Put the ESP32 in BLE commissioning/recovery mode and click **Scan for ESP32**.
2. Select the device, connect, and pair with `11111`.
3. Scan Wi-Fi networks or type the SSID, enter the passphrase, and choose **Save credentials & reboot**.
4. The app waits for the reboot, then broadcasts the UDP keepalive on port 8888. A manual ESP32 IP can be entered if broadcast discovery is unavailable.
5. Start the camera stream. The app receives UDP on the same ephemeral socket registered as the ESP32 peer.

BLE is used for commissioning and local GATT status only. Video and runtime commands run over the UDP peer socket.

## Tests

```bash
cd desktop
PYTHONPATH=. python3 -m unittest discover -s tests -v
python3 -m compileall -q spectrulenpor_console tests
```

No changes are made to NVS or ESP32 flash by launching this desktop app. Credentials are only sent when the user explicitly presses the provisioning button.

The source tree also contains a rebuilt ESP-IDF image with the expanded RSSI/channel and 18-channel sensor status fields. It is intentionally not flashed by the desktop launcher. Those additional fields appear after the updated firmware is explicitly deployed to the board.
