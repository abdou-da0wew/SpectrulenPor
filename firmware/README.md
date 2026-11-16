# SpectruLenPor ESP32-CAM Firmware

ESP-IDF firmware for the AI-Thinker ESP32-CAM. BLE handles initial setup; saved WiFi credentials select WiFi-only operation on the next boot. The application entry point is [`components/main/main.c`](components/main/main.c).

## Hardware

| Part | Role | Procurement |
|---|---|---|
| AI-Thinker ESP32-CAM, OV2640 | Camera, WiFi/BLE and onboard flash LED | [Maker Selectronics](https://makerselectronics.com/product/esp32-cam-esp32-s-wifibluetooth-with-ov2640-camera-module/) |
| ESP32-CAM-MB, CH340 | Micro-USB programming and 5 V power | [Maker Selectronics](https://makerselectronics.com/product/esp32-cam-mb-micro-module-esp32-cam/) |

| Signal | GPIO / bus | Notes |
|---|---|---|
| OV2640 | Onboard camera pins, I2C0 for SCCB | QVGA `320x240` over BLE; SVGA `800x600` over UDP with PSRAM |
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

TX carries raw JPEGs delimited by `FFD8` / `FFD9` and newline-delimited text. The maximum notification payload is the smaller of 500 bytes and negotiated MTU minus 3. Setup-mode sensor telemetry, when available, is scheduled every 500 ms.

| Command | BLE | UDP | Effect |
|---|---|---|---|
| `0x00` | Yes | Yes | Pause streaming and clear pending single requests; keep the UDP listener open |
| `0x01` | Yes | Yes | Resume streaming; UDP sender becomes the current peer |
| `0x02` | Yes | Yes | Queue one camera image without resuming a paused stream; UDP sender becomes the peer |
| `0x03` / `0x04` | Yes | Yes | Flash on / off |
| `0x05` | Yes | No | Legacy software restart |
| `0x06` | Yes | No | Standby: pause, flash off, stop WiFi; setup BLE remains available |
| `0x07` | Paired | No | Save credentials; two empty strings erase them |
| `0x08` | Yes | No | Read current SSID as `$WIFI_CFG:ssid=...\n`, never the password |
| `0x09` | Yes | No | Read connection and camera status |
| `0x0A` | Yes | No | Validate setup code |
| `0x0B` | Paired | No | Reboot into saved WiFi configuration; fails without credentials |

UDP frames retain the existing wire format: four little-endian `uint32` fields (`seq`, `total`, `offset`, `size`) followed by up to 512 JPEG bytes. Sequence numbering starts at zero for every frame; this protocol has no frame ID or retransmission guarantee. A new peer receives a one-byte `0x01` or `0x02` echo before image fragments. Only the current peer can pause or change the flash. Another sender can claim the stream with `0x01` / `0x02`.

`STREAM_INTERVAL_MS=100` is a scheduling target, not a measured 10 fps guarantee. Packet pacing and JPEG size affect actual throughput.

## Tests

Host C tests use strict compiler warnings and AddressSanitizer / UndefinedBehaviorSanitizer on GCC or Clang:

```sh
cmake -S tests -B build-host-tests -DENABLE_SANITIZERS=ON
cmake --build build-host-tests
ctest --test-dir build-host-tests --output-on-failure
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 -m unittest discover -s testbench/tests -p 'test_*.py' -v
```

Latest source-fix checks on 2026-11-15 passed **180 firmware + 124 testbench = 304 Python tests**, zero failures/errors/skips, with raw logs, timestamps and unchanged source identities retained. Fresh strict-warning/ASan/UBSan protocol checks passed 578 command, 11 JPEG and 8,974 UDP checks. The complete Flutter suite passed **190 tests**, zero failures/skips, and `flutter analyze --no-pub` reported zero issues. UDP delivery verified on real ESP32-CAM hardware: fresh WiFi-only boot, 800x600 JPEG decoded over UDP, zero send failures. The focused 62 Python, 30 session/WiFi host-C and 63 Flutter tests are subsets, not extra counts. Earlier 146 + 101 = 247 Python results have inline-only provenance; earlier 218/195 Python and 147 Flutter snapshots remain historical. Eight actual-sender and four actual-`app_main` NVS guard regressions are included in the firmware suite. Flutter acquisition stubs do not verify real Android scheduling or scans; the interrupted earlier full Flutter run is not a pass.

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
