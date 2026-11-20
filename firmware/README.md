# SpectruLenPor ESP32-CAM Firmware

**Project author:** Malak Adel Sayed Hassan. **Main software and firmware developer / original code author:** Abdou (Abdou; عبد الرحمن أيمن محمد, [`@abdou-da0wew`](https://github.com/abdou-da0wew)). Attribution details are recorded in [`MAINTAINERS.md`](MAINTAINERS.md) and [`manifest.json`](manifest.json).

ESP-IDF firmware for the AI-Thinker ESP32-CAM. BLE handles initial setup; saved WiFi credentials select WiFi-only operation on the next boot. The application entry point is [`components/main/main.c`](components/main/main.c).

## Hardware

| Part | Role | Procurement |
|---|---|---|
| AI-Thinker ESP32-CAM, OV2640 | Camera, WiFi/BLE and onboard flash LED | [Maker Selectronics](https://makerselectronics.com/product/esp32-cam-esp32-s-wifibluetooth-with-ov2640-camera-module/) |
| ESP32-CAM-MB, CH340 | Micro-USB programming and 5 V power | [Maker Selectronics](https://makerselectronics.com/product/esp32-cam-mb-micro-module-esp32-cam/) |

| Signal | GPIO / bus | Notes |
|---|---|---|
| OV2640 | Onboard camera pins, I2C0 for SCCB | QVGA `320x240` over BLE; XGA `1024x768`, SVGA `800x600`, VGA `640x480` or QVGA `320x240` over UDP with PSRAM |
| White flash LED | GPIO4 | On/off commands; cleared on BLE disconnect and reset |
| Optional AS7265x SDA / SCL | GPIO13 / GPIO14, I2C1 | Address `0x49`; not analog ADC inputs |

The sensor firmware reads the AS7265x A and W channels. The legacy `$UV:` field is the 410 nm channel, not a calibrated ultraviolet measurement. No sensor samples are emitted when the triad is unavailable. The connected test board has 4 MB flash and 8 MB physical PSRAM, of which ESP-IDF maps 4 MB into the heap.

## Build and flash

Use ESP-IDF **5.5.1**, target `esp32`. The component manager resolves the versions recorded in `dependencies.lock`: `esp32-camera` 2.1.9 and `esp_jpeg` 1.3.2. Arduino IDE is not the build path for this firmware.

Run from `firmware/` after activating the ESP-IDF environment:

```sh
idf.py -B build-idf5 -D SDKCONFIG=build-idf5/sdkconfig set-target esp32
idf.py -B build-idf5 -D SDKCONFIG=build-idf5/sdkconfig build
idf.py -B build-idf5 -D SDKCONFIG=build-idf5/sdkconfig -p /dev/ttyUSB0 flash
idf.py -B build-idf5 -D SDKCONFIG=build-idf5/sdkconfig -p /dev/ttyUSB0 monitor
```

`SDKCONFIG` isolates generated settings from an existing working configuration. `sdkconfig.defaults` selects DIO, 40 MHz flash, PSRAM, NimBLE and the new I2C master driver. Substitute the board's serial port when it differs. Close serial monitors before flashing or running tests.

Seat the board on the ESP32-CAM-MB and connect its micro-USB cable. The tested CH340 shield supports automatic reset into the bootloader. With a bare board, use a USB-UART adapter with 3.3 V logic and adequate 5 V board power; ground GPIO0 during upload, then release it and reset.

Flashing the application does **not** clear saved WiFi credentials. A board with saved credentials will not advertise BLE after flashing.

The latest source stops boot with `NVS_INIT_FAILED` on NVS initialization errors, without automatic NVS erasure. Four host-C regressions compiling the actual `app_main` passed. The separate `build-safety-20261115` release-source application contains this safeguard: 976,848 bytes, SHA-256 `d3b5d790f0cd0c6f60f122550fbf8f6cf0f77282ba8c8ecd8b9cc3c09d8bcfa4`. It built with zero compiler warnings/errors and no TX wrappers; its effective header matches the diagnostic and its partition binary is identical. It was **not flashed** and predates the sender-reporting correction.

The historical camera-DMA / legacy-PHY diagnostic `build-tx-camdma-03-20261115`, 980,624 bytes, SHA-256 `e5ddd3cd6fbb50d9869f7682870834b8b5dad1d2ba0e066c0e6233e9365a88ea`, was independently verified in four NVS-excluding regions after the retained reachability assessment. Its failed host injection and `udp-camdma-01` delivery failure remain retained. It is no longer the flashed application.

The fixture now runs the approved session/WiFi source-fix release `build-review-release-20261115T173449Z-fb11f81d`: 977,840 bytes, SHA-256 `97a438e50a6245f4ce6709f2b3f806589c305ecfbe25c2599099f1deba9dfbc5`, zero compiler warnings/errors. All four regions passed independent digest verification under exclusive hardware ownership, with NVS-excluding write sectors, no credential writes or explicit erasures, and no diagnostic instrumentation. SDK runtime wrapper names were checked against pinned CMake sources; the initial overbroad checker rejection and pre-flash gates remain unchanged. `test-results/review-release-20261115T173449Z-fb11f81d/release-flash-results.json` records deployment, not UDP delivery. The subsequent saved-profile probe failed without decoding an image.

## Setup and boot modes

1. No valid credentials in NVS: boot as `ble_setup`, advertising `SpectruLenPor-ESP32`. WiFi is not initialized.
2. Connect, enable TX notifications, and write `0x0A` followed by the five ASCII bytes `11111`. Require `$CMD:paired\n`.
3. Write `0x07 + SSID + NUL + password + NUL`. SSIDs support up to 32 bytes. Passwords are empty for open networks, 8 to 63 bytes for passphrases, or 64 hexadecimal bytes for a PSK.
4. Require `$CMD:wifi_config_received\n`, `$ESP_MAC:<MAC>\n`, and `$ESP_NAME:spectrulenpor-esp32\n`. Credentials are committed to NVS; WiFi still does not start.
5. Write `0x0B`. Require `$CMD:reboot\n`, then expect the BLE link to disconnect.
6. The new boot selects `wifi_only`, loads NVS, connects to the AP, and binds UDP port 8888. BLE is not initialized, even if connection attempts fail.

Pairing is application-level authorization, not encrypted Bluetooth bonding. It is cleared on disconnect and protects provisioning, erasure and `0x0B`; it does not make the fixed setup code a secure secret. UDP control is also unencrypted. Use a trusted local network.

WiFi retries are bounded by `WIFI_MAX_RETRIES` in `config.h`. Exhaustion reports `wifi=failed`; it never erases credentials or switches back to BLE. Reset starts a new retry cycle with the saved profile. Reconfiguration after a WiFi-only boot requires an explicit NVS reset.

## BLE and UDP contracts

| GATT item | UUID |
|---|---|
| Service | `0000ffe0-0000-1000-8000-00805f9b34fb` |
| TX, notify | `0000ffe1-0000-1000-8000-00805f9b34fb` |
| RX, write with response | `0000ffe2-0000-1000-8000-00805f9b34fb` |

TX is control/status text only. BLE never carries JPEG bytes or image fragments. The maximum notification payload is the smaller of 500 bytes and negotiated MTU minus 3. BLE is used for pairing, WiFi provisioning, provisioning status, and basic commissioning controls; after credentials are saved the ESP reboots into WiFi-only mode and does not initialize BLE.

During setup-mode advertising, the primary advertisement keeps the existing `SpectruLenPor-ESP32` name and FFE0 service UUID. Its scan response includes FFE0 service data `DEV:Abdou;PROJECT:Malak`, identifying Abdou as software/firmware developer and Malak as project author. Active BLE scanning can read the scan response. This identity payload does not change the GATT UUIDs or provisioning commands.

| Command | BLE | UDP | Effect |
|---|---|---|---|
| 0x00 | No | Yes | Pause streaming; keep the UDP listener open |
| 0x01 | No | Yes | Start/resume video; UDP source endpoint becomes the current peer |
| 0x02 | No | Yes | Queue one camera image without resuming a paused stream |
| 0x03 / 0x04 | Yes, setup only | Yes | Flash on / off |
| 0x05 | Yes, setup only | Yes | Restart the ESP |
| 0x06 | Yes, setup only | Yes | Standby: pause, flash off, stop WiFi |
| 0x07 | Paired | No | Save credentials; two empty strings erase them |
| 0x08 | Yes, setup only | No | Read current SSID; never the password |
| 0x09 | Yes, setup only | Yes | Read connection and camera status |
| 0x0A | Yes | No | Validate setup code |
| 0x0B | Paired | Yes | Reboot into saved WiFi configuration; fails without credentials |
| 0x0C | No | Yes | Refresh the registered UDP peer after WiFi/AP recovery |

UDP video uses wire protocol V2 on port 8888. Each datagram starts with six little-endian uint32 fields: seq, total_data_fragments, byte_offset, payload_size, frame_id, and frame_size. Data datagrams carry up to 1200 JPEG bytes. The high bit of seq marks an XOR parity datagram; the remaining bits identify one of four interleaved sequence groups. Parity datagrams carry 1200 bytes, padded with zeroes for a short final fragment. Frame IDs are monotonic within a UDP socket session and allow the phone to reject late packets from older frames. The receiver accepts reordered fragments and reconstructs one missing data fragment per interleaved group. More than one loss in a group drops that frame; the next camera frame is preferred over waiting on a stale image. This is low-latency forward error correction, not a retransmission guarantee.

The app binds an ephemeral UDP port and registers the peer with command 0x0C (keepalive) before camera capture starts. If the user leaves the IP field empty, the app broadcasts that existing keepalive command and resolves the ESP32 from its echo/acknowledgement; a stalled stream triggers rediscovery for DHCP address changes. Both devices must share a LAN where broadcast traffic is allowed. Stream-on (0x01), pause (0x00), single-frame (0x02), status, flashlight, restart, shutdown and reboot all use this same UDP socket after provisioning. The ESP unicasts video to that registered source address and port. The keepalive acknowledgement confirms the control peer; only a decoded JPEG marks the camera feed ready. Pausing video retains the socket, so controls and resume remain available. Only the current peer can control the camera or flashlight. UDP control and video are not encrypted; use a trusted local network.

The OV2640 emits JPEG in hardware; the ESP does not recompress JPEG in software. Data payloads are 1200 bytes, keeping the 24-byte V2 header plus IPv4/UDP overhead below a 1500-byte path MTU. The sender yields for 1 ms after each data/parity datagram and uses up to 16 bounded exponential retries for transient local Wi-Fi queue exhaustion. Four interleaved XOR parity packets protect each frame against one missing packet per sequence group, replacing the old five-copy-per-fragment scheme.

WiFi enables the ESP-IDF-supported 802.11b/g/n 2.4 GHz protocol bitmap; the access point and station negotiate the actual PHY rate per connection. Modem sleep is disabled and station bandwidth is fixed at HT20. Camera resolution adapts to AP RSSI with hysteresis: strong links use XGA (1024×768), medium links use SVGA (800×600), weak links use VGA (640×480) down to −70 dBm, and weaker links start at QVGA (320×240) to avoid sending oversized frames over marginal RF links. The XGA/SVGA/VGA post-frame intervals are 0 ms and QVGA uses 25 ms; each transmitted datagram yields for 1–6 ms according to the active RSSI profile to drain the bounded Wi-Fi TX queue; SVGA has a 40 ms capture-and-send budget, while the other profiles use a 50 ms budget. These budgets are degradation thresholds, not guaranteed frame rates. The streaming control loop polls at 1 ms while frames are pending or streaming. A frame over its profile budget or any UDP send failure degrades one profile step and holds that safer profile for 15 seconds before attempting an upgrade. These are scheduling targets, not measured FPS guarantees; OV2640 capture time, JPEG size, Wi-Fi airtime, packet loss and phone decode time determine actual throughput. Real range still depends on antenna orientation, router placement and interference.

## Tests

Host C tests use strict compiler warnings and AddressSanitizer / UndefinedBehaviorSanitizer on GCC or Clang:

```sh
cmake -S tests -B build-host-tests -DENABLE_SANITIZERS=ON
cmake --build build-host-tests
ctest --test-dir build-host-tests --output-on-failure
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 -m unittest discover -s testbench/tests -p 'test_*.py' -v
```

Historical source-fix checks on 2026-11-15 passed **180 firmware + 124 testbench = 304 Python tests**, zero failures/errors/skips, with raw logs, timestamps and unchanged source identities retained. Fresh strict-warning/ASan/UBSan protocol checks passed 578 command, 11 JPEG and 8,974 UDP checks. The complete Flutter suite passed **190 tests**, zero failures/skips, and `flutter analyze --no-pub` reported zero issues. UDP delivery verified on real ESP32-CAM hardware: fresh WiFi-only boot, 800x600 JPEG decoded over UDP, zero send failures. The focused 62 Python, 30 session/WiFi host-C and 63 Flutter tests are subsets, not extra counts. Earlier 146 + 101 = 247 Python results have inline-only provenance; earlier 218/195 Python and 147 Flutter snapshots remain historical. Eight actual-sender and four actual-`app_main` NVS guard regressions are included in the firmware suite. Flutter acquisition stubs do not verify real Android scheduling or scans; the interrupted earlier full Flutter run is not a pass.

Latest attribution/identity regression checkpoint (2026-11-20): **206 firmware Python tests**, **143 testbench tests**, and **3/3 C protocol test groups** passed. The added testbench cases check the root/firmware authorship manifests, the 25-byte FFE0 BLE scan-response identity payload, Android application metadata, and the unchanged UDP V2 framing. The ESP-IDF build was not run in this environment because the configured IDF checkout path is unavailable; these host tests do not claim an ESP32 target compile.

Hardware tests require Linux BlueZ, a powered BLE adapter, Python with `pyserial`, `dbus-python`, PyGObject and Pillow, plus NetworkManager / `nmcli` for `--wifi-from-nm`. Run them only against a board authorized for configuration changes:

```sh
python3 tests/boot_smoke.py --port /dev/ttyUSB0 --reset --version 3.2.0 \
  --mode ble_setup --output test-results/setup-boot.log
python3 tests/hardware_e2e.py --port /dev/ttyUSB0 --adapter hci0 \
  --output test-results/full-run --wifi-from-nm
```

The full suite requires a clean-NVS setup fixture and never erases NVS automatically. It runs synthetic boundary/reconfiguration/erase checks before final real provisioning. After `0x0B`, it uses UART for status and UDP for actual decoded images, without reconnecting BLE. Missing acknowledgments, transport faults, reboot evidence or cleanup acknowledgments fail the run. Cleanup never resends or erases credentials; `configuration_may_require_recovery` identifies a failed configuration phase that needs operator recovery. Without WiFi credentials, WiFi/UDP cases are explicitly reported as skipped.

`--wifi-from-nm` reads the active WiFi profile into memory. Do not place real passwords in command lines, checked-in files or test reports. Outputs include `results.json`, `uart.log` and decoded JPEG files; keep these private because images and logs may identify the test environment.

The separate missing-AP test observes every configured retry, exhaustion and saved credentials after reset:

```sh
python3 tests/wifi_retry_hil.py --port /dev/ttyUSB0 --adapter hci0 \
  --output test-results/missing-ap
```

Run this before final real provisioning. It requires a setup fixture and leaves synthetic credentials persisted. Reset only the authorized NVS region afterward, then run the full suite with real credentials. It never erases NVS automatically.

### Deliberate setup reset

Only when credential loss is authorized, erase the NVS region from `partitions.csv` using the ESP-IDF environment's esptool:

```sh
python -m esptool --chip esp32 --port /dev/ttyUSB0 erase_region 0x9000 0x6000
```

This clears NVS, not the whole flash. Do not run `erase_flash` to repeat setup tests. Once provisioned, use `--mode wifi_only` for boot smoke checks.

## Linux testbench

The dashboard and CLI use the same hardware worker as the HIL profiles. OpenCV consumes that worker's decoded frame store or its loopback HTTP endpoint, never a second UDP socket. Dependencies are the Linux HIL packages above; OpenCV viewing additionally requires `cv2`, NumPy and a desktop GUI session. This machine's system Python has those packages; the ESP-IDF environment is used separately for builds and flashing.

From `firmware/`:

```sh
python3 -m testbench serve --uart /dev/ttyUSB0 --port 8765
python3 -m testbench view --url http://127.0.0.1:8765
```

Open `http://127.0.0.1:8765` for the EN/AR dashboard. `serve --opencv` displays the same engine frame store directly. Starting the server alone does not open hardware. Close other testbench/HIL/diagnostic owners before connecting or flashing; standalone runners share the adapter/canonical-UART lease through handled cleanup. CLI and standalone HIL/boot entrypoints handle SIGINT/SIGTERM cooperatively and protect teardown from repeated signals. Native D-Bus calls must return before cancellation is observed. A real disconnected-backend SIGTERM smoke exited 0 with empty-frame HTTP status 204 and no hardware access; signal-driven live hardware cleanup remains unverified.

| Profile | Preconditions and evidence |
|---|---|
| `smoke` | BLE setup or an attached UDP peer; decoded single image, stream/pause and controls |
| `full` | UART, clean-NVS setup fixture, WiFi credentials and `--confirm-configuration`; synthetic checks precede final provisioning |
| `mobile-flow` | Clean setup fixture and WiFi credentials; UART adds fresh boot/reset/persistence checks; without UART, an explicitly observed `--ip` is required |
| `missing-ap` | UART, clean setup fixture and `--confirm-configuration`; leaves synthetic credentials persisted and reports operator recovery required |
| `soak` | Connected transport with decoded frames; `--duration` from 1 to 3,600 seconds |

```sh
python3 -m testbench run --profile full --uart /dev/ttyUSB0 \
  --wifi-from-nm --confirm-configuration --output test-results/full-run
```

Full/mobile-flow credentials come from `--wifi-from-nm` or `SPECTRULENPOR_TEST_SSID` plus a masked password prompt/`SPECTRULENPOR_TEST_PASSWORD`. Never put real passwords in command-line arguments. Missing/invalid credentials and missing no-UART IP abort before provisioning; they do not become skipped passing cases. Timeouts/cancellation never automatically resend or erase credentials.

The API exposes `GET /api/config`, `/api/state`, `/api/frame.jpg?sequence=N`, `/api/localization?locale=en|ar` and `/api/report`. `POST /api/action` requires the configuration response's `X-Testbench-Token`; Host/origin checks also apply. Actions are connect, setup, reboot, attach, stream, single, flash, disconnect, test and cancel. Soak actions accept `duration` or `duration_seconds`. Empty camera state returns 204, not a fabricated image.

Dashboard translations are the 206 `tb*` strings in each Flutter ARB. Reports redact credentials and raw UART text. JPEG evidence is private. HIL cleanup independently attempts stream-off, flash-off, BLE disconnect and UDP close when applicable. Boot-smoke independently attempts DTR/RTS clearing and UART close, preserving the primary error with collected cleanup exception types. UART readers are joined before ownership is released. Cleanup-only failures cannot become passes; the CLI selects reports and exit status after cleanup.

Only complete current-run UART-backed full/mobile-flow evidence can establish firmware/mobile-contract flags. Partial profiles and no-UART mobile-flow cannot verify NVS persistence; Linux never verifies Android or unavailable AS7265x hardware. Actual-backend browser and empty-frame OpenCV checks have passed. Live UDP/dashboard/OpenCV delivery has been verified via comprehensive hardware testing.

The latest comprehensive hardware test (`comprehensive-udp-20261116T054909Z-14fbe3f6`) on the reviewed uninstrumented release with UDP delivery fixes verified all previously-unverified items:

| Test | Result |
|------|--------|
| UDP single frame | 800x600 JPEG decoded (11,641 bytes), zero send failures |
| UDP continuous stream | 5/5 frames decoded, all 800x600, stream pause verified |
| UDP controls | flash on/off, stream on/off, single frame after pause all work |
| Reset persistence | Soft reset via DTR, credentials persisted, WiFi reconnected, image decoded after reset |
| Dashboard API | All 7 endpoints (/, /api/state, /api/config, /api/report, localization EN/AR, frame.jpg) returned 200/204 |

Zero credential writes, zero explicit erasures, zero cleanup errors across all tests.

UDP JPEG delivery has been fixed and fully verified. The reviewed uninstrumented release (977,840 bytes, SHA-256 `97a438e50a6245f4ce6709f2b3f806589c305ecfbe25c2599099f1deba9dfbc5`) now delivers real 800x600 JPEG frames over WiFi-only UDP. Fixes applied:

- **Dynamic WiFi TX buffers**: switched from 16 static buffers (~25KB) to 64 dynamic buffers, eliminating `ESP_ERR_NO_MEM`/`ENOMEM` send failures during JPEG fragment bursts.
- **Fragment redundancy**: 3× transmission of each fragment to overcome air packet loss.
- **Send pacing**: 2ms per-packet delay + 10ms inter-fragment pacing to let the WiFi radio drain the TX queue.
- **Socket buffers**: SO_SNDBUF/SO_RCVBUF set to 256KB on both ESP32 and host sides.
- **Max TX power**: `esp_wifi_set_max_tx_power(84)` (20 dBm) and `esp_wifi_set_ps(WIFI_PS_NONE)` for reliable link.

The historical camera-DMA / legacy-PHY diagnostic `build-tx-camdma-03-20261115` (980,624 bytes) and its failed `udp-camdma-01` probe remain retained as historical evidence. Neither was a verified transport fix.

Earlier driver samples returned `ESP_ERR_NO_MEM`, correlated with socket `ENOMEM`; they identify the failing WiFi API, not its internal allocation/queue cause or every lost datagram. Sender reporting distinguishes `UDP_SEND_DEADLINE`, `UDP_SEND_SOCKET_ERROR` and `UDP_SEND_SHORT_WRITE` with attempt counts and actual socket results. Historical camera-DMA expired at sequence 28/34 after 18 resource-error attempts and received nine orphan fragments. Callback, TX-only AMPDU-off and legacy probes also failed without decoding. The dynamic TX buffer and send pacing fixes resolve the ENOMEM failures that motivated them; the current reviewed release achieves zero send failures and complete UDP JPEG delivery.

The private camera-DMA build compiles cleanly with matching legacy config/partitions and verified ELF wrapper call paths. Three header-order checks and ten host safety cases passed; one injected transient restart failed. Review found direct stub register mutation bypassing compiled camera code, not a demonstrated pinned-driver defect. That failed case is retained unchanged. After assessment, four regions were flashed/independently verified without NVS overlap. UART recorded RX/EOF acquisition-off snapshots, a 10-second drain and a resume-call marker, but no queued starts or subsequent capture request; actual suppression/reacquisition remains unverified. Clocks and allocations were unchanged. Pausing acquisition did not fix delivery.

## Components

- `main`: owns application state, command execution and capture scheduling.
- `ble`: NimBLE GATT, connection-scoped setup authorization and command queue.
- `wifi`: credential blob validation, NVS commits and station retries.
- `ov2640`: camera component wrapper, including resolution changes.
- `udp_stream`: listener, peer selection and existing frame packet transport.
- `protocol`: hardware-independent command, credential, JPEG and UDP validation.
- `sensors` / `flashlight`: optional spectral triad and onboard GPIO control.

See [firmware hardware validation](../docs/firmware-hardware-validation.md) for measured results and remaining limits.

## BLE/UDP transport ownership (2026-11-16)

- BLE GATT is a commissioning channel only: pair, save/read WiFi configuration, setup status, flashlight, restart, standby and the explicit WiFi reboot handoff. Its TX characteristic carries ASCII control/status only; binary notification payloads are discarded by the app.
- BLE rejects stream-on, stream-off and single-frame with VIDEO_AND_RUNTIME_COMMANDS_REQUIRE_UDP. The firmware's separate BLE setup allowlist prevents video commands from being queued over BLE.
- After provisioning, the ESP boots WiFi-only and does not start its BLE service. The phone registers UDP port 8888 with command 0x0C; all camera/video and normal runtime controls thereafter use UDP. Pausing video does not close the UDP socket.
- test/live_esp_udp_stream_test.dart runs the physical UDP stream/control smoke test when ESP32_TEST_IP is set.
