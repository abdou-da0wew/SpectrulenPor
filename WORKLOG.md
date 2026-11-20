# WORKLOG.md — dated engineering log

## 2026-11-20: UDP V2 transport, mobile runtime modules and responsive app refresh

### Firmware and end-to-end camera transport

- Move the ESP32-CAM sender and Flutter receiver to the same UDP V2 contract: a six-word header, 1200-byte JPEG payloads, frame/session identity, interleaved XOR parity recovery, and strict malformed/stale-fragment rejection.
- Add a PSRAM-backed Wi-Fi TX cache (40 static buffers plus 128 cache buffers), transient send retries, RSSI-aware packet pacing and a conservative weak-link startup profile. Keep the ESP-IDF-supported 2.4 GHz b/g/n protocol bitmap; test AMPDU TX disabled as a separate weak-link configuration.
- Improve the HIL around peer registration, one-shot frame requests, duplicate control acknowledgements, status-based stream-stop verification, and quiet-window detection that distinguishes image packets from control traffic.
- Add firmware maintainer and manifest metadata. Keep Wi-Fi credentials in NVS; no real SSID/password values are stored in source-controlled files.

### Flutter and Android feature work

- Split BLE responsibilities into `ble_protocol.dart`, `ble_session_manager.dart`, and `jpeg_frame_decoder.dart`, leaving `BluetoothCameraService` as the application-facing orchestrator.
- Harden native Android YOLO26 inference and the Flutter recognition/frame state lifecycle. Separate high-frequency preview updates from broader app-state notifications and improve bounding-box interaction.
- Add live OpenRouter free-model discovery, model capability metadata, custom-free-model validation and completion tests. Reframe lexical evidence as candidate source matching, not claim verification.
- Add native Vosk speech recognition and Supertonic TTS channels, language-aware text correction, and more robust cloud-to-local speech fallback.
- Introduce a responsive HomeLayout, shared Phosphor icon mapping, settings categories, Android home-screen widget/deep links, and local notification flows. Improve diagnostics/history UI and preserve the nine-table storage contract.
- Update English/Arabic strings and the app's agent/contributor context. Add a metadata-aware Flutter wrapper so source-control details are generated at build time rather than committed as stale values.

### Verification and known limits

- Firmware C protocol suite: **3/3 passed**. Firmware Python tests passed; the UDP testbench suite passed **139 tests**.
- Focused TTS and speech-correction suites: **13/13 passed** after fixing inline-code backticks in markdown-to-speech cleanup.
- Full Flutter run at this checkpoint: **218 passed, 4 skipped, 13 failed**. Failures included BLE setup/reboot test expectations, stale widget/settings text assertions, a Wi-Fi setup-state expectation, and the optional raw ESP probe when its target variable was absent. After that run, the raw hardware probe was changed to skip when `ESP32_TEST_IP` is unset and the TTS sanitizer issue was fixed; the complete Flutter suite was not rerun afterward. Full `flutter analyze` did not finish in the constrained shell and is not claimed green.
- Physical ESP32-CAM smoke tests decoded JPEGs successfully on selected builds. One 60-second AMPDU-on soak measured 210 frames at 3.50 FPS with no incomplete frames or protocol errors; later sustained runs were inconsistent. The latest AMPDU-off soak measured about 1.5 FPS, one incomplete frame, and a control timeout. The requested **20–30 FPS has not been achieved**; resolution, cadence and link reliability still require further hardware work.

### Commits created in this series

- `0677d45` firmware UDP V2 and HIL transport work
- `be871fd` BLE session and JPEG decoder refactor
- `9ac9568` OpenRouter model catalogue and grounded AI response flow
- `c35ac85` native YOLO and recognition-state work
- `197f05e` Flutter UDP V2 camera client
- `8df3043` Vosk and Supertonic speech pipeline
- `d027423` Android build and native plugin classpaths
- `5c27078` storage, diagnostics and history
- `2229341` responsive UI, Phosphor icons and app widget
- `39e878a` English/Arabic localization
- `f167866` Git co-author hook and read-note acknowledgement

---

Reverse-chronological record of what was built, fixed, and verified. Unmerged work is labelled explicitly.

## 2026-11-16: BLE service refactor — split bluetooth_camera_service.dart into modules, uncommitted

### Refactor completed

Split the monolithic `lib/services/bluetooth_camera_service.dart` (868 LOC, with triplicate `_write`/`_confirmedWrite` definitions and no public setup commands) into four focused modules:

| File | Size | Responsibility |
|---|---|---|
| `lib/services/ble_protocol.dart` | 52 LOC | BLE GATT contract: UUIDs, command bytes, pairing code, timeouts, MTU, frame size limits |
| `lib/services/ble_session_manager.dart` | 379 LOC | BLE session lifecycle: connect, MTU negotiation, service discovery, notification subscription, cancel/disconnect release, auto-reconnect with capped exponential backoff, failed-release ownership for explicit retry |
| `lib/services/jpeg_frame_decoder.dart` | 108 LOC | JPEG reassembly state machine: SOI (FFD8)/EOI (FFD9) detection across chunk boundaries, O(chunk) per notification, max-frame guard |
| `lib/services/bluetooth_camera_service.dart` | 616 LOC | Clean orchestrator: public API (`blePair`, `wifiConfigPut`, `reboot`, `scanAndConnect`, `disconnect`, `dispose`, `init`), status/frame/sensor streams, confirmed-write with acknowledgment timeout, shutdown commands on disconnect, text telemetry handler, auto-reconnect scheduling |

### Architecture of the split

- `BleSessionManager` owns all raw BLE resource handling (connect, MTU, service discovery, notification subscribe/cancel, device disconnect, auto-reconnect timer). It never knows about pairing, provisioning, or status streams. It exposes `session`, `rxChar`, `device`, `hasSession`, `isConnected`, `reconnectSuppressed`, `reconnectInFlight`, `releasesPending`, `cleanupComplete`, plus `connect()`, `disconnect()`, `dispose()`, `releaseRetiredSessions()`.
- `BluetoothCameraService` owns service-specific state (`_paired`, `_configuredThisSession`, `_sessionReady`, `_deviceName`, pending-line acknowledgments), public command methods, all streams, and the `JpegFrameDecoder` instance. Notifications are dispatched: `$`-prefixed text goes to `_handleTextLine()` (spectrum readings / status messages), binary data goes to `_jpegDecoder.feed()` → `FrameData` → `_frameCtl`.
- `JpegFrameDecoder` is a pure state machine with no Flutter dependencies beyond `debugPrint`: SOI/EOI detection honoring split markers, `feed()` returns `FrameData?` when a frame completes.
- UUID matching fixed to use `Guid.str128` (the platform interface returns shortened `str` like `'ffe0'` from `toString()`; `str128` returns the full `0000ffe0-0000-1000-8000-00805f9b34fb`).

### Verification status (post-refactor)

- `flutter analyze lib/services/ble_session_manager.dart lib/services/bluetooth_camera_service.dart lib/services/ble_protocol.dart lib/services/jpeg_frame_decoder.dart`: **0 errors / 0 warnings** (2 minor info-level suggestions remain)
- `flutter test test/services/glasses_ble_acquisition_test.dart`: **13 passing, 30 failing** — failures are test-infrastructure mismatches against the refactored service (UUID matching was fixed; remaining failures involve shutdown-command timing, late-release behavior, and reconnect timing that need test-side adjustments). Not all failures are logic regressions; several are timing/sequence expectations that predate the split.
- Full `flutter test` suite: **not yet re-run** after the refactor. The previous complete run was **190 passing, 0 failing, 0 skipped**. Must be re-verified before shipping.
- `flutter analyze` full project: **not yet re-run** after the refactor. Previous was 0 issues.

### Known incomplete items (handoff)

1. **Fix remaining 30 test failures** in `glasses_ble_acquisition_test.dart` — the test fakes (`FakeAcquisitionDevice`, `TrackedBleStream`) and test expectations need alignment with the new `BleSessionManager` boundaries. Specifically: shutdown commands sent during `disconnect()` while no session is active now throw `bleUnavailable` (they previously were guarded differently); late-release timing and reconnect backoff expectations need test updates.
2. **Re-run full `flutter test`** to confirm 190-passing baseline is maintained.
3. **Re-run `flutter analyze`** full project to confirm 0 issues.
4. **Real-phone Android verification** of BLE scan/connect/pair/provision/reboot/UDP preview remains pending (app installed on phone EE441L013755, Android 14, but not configured for ESP IP 192.168.1.158).
5. **Commit and push** all uncommitted changes: `ble_session_manager.dart` (new), `jpeg_frame_decoder.dart` (new), `bluetooth_camera_service.dart` (rewritten), plus any test updates.

### Prior completed work (retained from earlier sessions)

- Firmware 3.2.0 UDP delivery fixed on real hardware: dynamic WiFi TX buffers (64), 3× fragment redundancy, 2ms/10ms pacing, 256KB socket buffers, 20 dBm TX power, power save disabled. Comprehensive UDP test passed all 4 groups (stream 5/5, controls, reset persistence, dashboard API 7/7).
- ESP32-CAM provisioned with "Orange EG" WiFi, IP 192.168.1.158, fresh WiFi-only boot verified via UART.
- Flutter APK built (212.6MB), installed on Android phone EE441L013755, launched successfully.
- 190 Flutter tests passing, 0 analyzer issues (pre-refactor baseline).
- All firmware/testbench Python suites passing (304 tests).
- Evidence index: 1249 entries, aggregate flags false. Everything unstaged, uncommitted, unpushed.

## 2026-11-16: scientific source-match, corpus provenance and build identity fixes

### Changes completed

- Corrected the PET example CAS in both English and Arabic OpenRouter system prompts to `25038-59-9`, matching the bundled corpus. Added a regression assertion that rejects the old number.
- Restored missing OpenRouter prompt/chat APIs (`_systemPrompt`, `_buildUserPrompt`, `streamChat`, `streamRawMessages`, `_streamRawOne`) from the committed implementation while retaining the Nemotron → Gemma → Inkling order. The analysis SSE path now uses the injected HTTP client, so tests and transport overrides control requests. Fixed the `isAr` return type and made the English hazard prefix explicit.
- Corrected the English and Arabic Settings labels to match the actual model-chain indexes.
- Marked Ununennium as hypothetical and its numerical properties as theoretical predictions; detailed retrieval now passes an explicit not-experimentally-measured warning to the model.
- Reframed the lexical claim checker as candidate source matching. Chat markers, counts, UI, and bilingual labels no longer claim token overlap proves a claim. The UI explains that lexical overlap is only a relevance hint. Existing SQLite column names are retained for on-device compatibility, but now map to source-match counts.
- Removed stale Git SHA/branch/dirty/build-date data from the checked-in version asset. Added `tooling/flutter_with_metadata.sh` to inject live Git and build metadata. Direct Flutter builds without the wrapper now show source-control metadata as unavailable rather than borrowing an old commit.

### Verification

- Focused Flutter suites: **35 passing, 0 failing** across scientific retrieval/fact matching, bilingual localization, internal DB persistence, OpenRouter streaming, and version metadata.
- `tooling/flutter_with_metadata.sh build apk --release` was exercised with a fake Flutter executable; it passed package version/build, current Git SHA/full SHA, branch, dirty state, and UTC timestamp as `--dart-define` arguments.
- Full-project `flutter analyze` still reports **39 errors**, all from the pre-existing BLE orchestrator/API mismatch between `RecognitionState` / `GlassesSetupCard` and the in-progress `BluetoothCameraService` rewrite. No analyzer diagnostics were reported in the files touched for this entry. Full test suite and Android device verification remain pending.

## 2026-11-16: OpenRouter model catalog correction

### Issue found during current model-catalog review

- The configured third model, `liquid/inkling-small:free`, was stale/invalid. The older Inkling Small free endpoint was retired on 2026-11-04; the current free Inkling successor is `thinkingmachines/inkling-2-small:free` (released 2026-11-09).
- Replaced the third model ID in `OpenRouterService.modelChain`, English and Arabic Settings labels, and architecture documentation. The display name is now Inkling 2 Small, not Liquid Inkling Small.
- Added a unit regression test pinning all three configured IDs.
- OpenRouter's current catalog pages list Nemotron 3.5 Super VL, Gemma 4 26B A4B, and Inkling 2 Small under the configured IDs. Catalog validation does not prove authenticated inference succeeds.

### Verification

- `flutter gen-l10n` completed successfully after the English and Arabic label changes.
- Focused suites: **36 passing, 0 failing**; the three opt-in authenticated model tests were intentionally skipped because `OPENROUTER_TEST_API_KEY` was not present in the test environment.
- Targeted `flutter analyze` on `OpenRouterService`, Settings, and the two OpenRouter test files: **0 errors**, 9 info-level style lints.
- Authenticated live streaming for each model is still unverified. `test/live_openrouter_models_test.dart` reads `OPENROUTER_TEST_API_KEY` from the process environment and asserts that each requested model itself serves a streamed response, without accepting a later fallback as success. No credential is embedded in source or test logs.

## 2026-11-16: UDP video transport V2 and RSSI-adaptive camera profiles

### Problems addressed

- The old wire format used 512-byte fragments, five copies of each datagram, and 10 ms pacing both between copies and between packets. This consumed airtime and made a frame burst unnecessarily long.
- The mobile and HIL receivers assumed strictly ordered packet arrival and had no frame identity. Packet loss or reordering could discard a mostly received JPEG or allow late fragments to contaminate the next frame.
- A fixed SVGA bitrate did not adapt to a weaker AP link.

### Changes

- Replaced the 16-byte V1 header with a 24-byte V2 header: sequence, total data fragments, byte offset, payload size, frame ID, and full frame size.
- Increased data payloads to 1200 bytes and removed fivefold unconditional fragment duplication. The ESP now retries only transient local UDP socket-buffer errors with bounded exponential backoff and a frame deadline.
- Added one XOR parity datagram per group of eight data fragments. Receivers can reconstruct one missing fragment per group without a request/response round-trip. Frames with multiple losses in one group are discarded; newer frames replace stale partial frames.
- Updated Flutter, hardware HIL, and Python testbench receivers to parse V2, accept out-of-order fragments, track frame IDs, and recover missing chunks. Added a standalone Dart suite that uses the production JPEG decoder.
- Added RSSI sampling and camera bitrate adaptation with hysteresis: SVGA/10 fps target, VGA/8 fps, QVGA/6 fps, and conservative QVGA/4 fps target. WiFi power save is disabled, HT20 is selected, and the existing max-TX API value 84 is documented as 20 dBm (ESP32 driver ceiling).
- Added regression tests for the V2 header, FEC recovery, out-of-order arrival, conflicting/malformed packets, frame-ID wraparound, old-frame rejection, and multiple loss behavior. Updated the host sender harness to compile the actual sender function.

### Verification

- Firmware Python suite: 179 passing, 0 failing.
- Firmware testbench suite: 126 passing, 0 failing.
- Standalone Flutter V2 receiver suite: 4 passing, 0 failing; dart analyze on the UDP receiver and isolated test: no issues.
- Host C protocol/codec suite: 3/3 passing.
- Actual-source UDP sender host harness: 8/8 passing.
- Physical ESP-IDF build and hardware flash/range test remain pending. The machine's saved ESP-IDF environment points to /home/aboood/esp-idf, which is absent, and no serial device is currently attached. The existing IDF build directory therefore cannot regenerate or compile the firmware here; it fails before compilation due to missing ESP-IDF CMake files/toolchain. No claim of real-device verification is made for V2.

## 2026-11-16: Enforce BLE commissioning-only and UDP runtime/video

### Transport policy and implementation

- Removed the BLE camera fallback from capture_and_send(): the firmware now sends JPEG frames only through udp_stream_send_frame(). BLE notifications are limited to setup/status text.
- Added an explicit firmware BLE setup allowlist. BLE stream-on, stream-off and single-frame commands are rejected with VIDEO_AND_RUNTIME_COMMANDS_REQUIRE_UDP; setup/basic local controls remain accepted.
- Reconcile a new BLE session before rejecting a forbidden video command, preventing a rejected command from leaving app/firmware session bookkeeping stale.
- Refactored WifiUdpVideoService into a persistent UDP runtime channel and a separate video state: connect() registers the UDP peer without starting capture, start() starts/resumes video, pause() stops capture but preserves the socket, disconnect() closes the transport. Flash/status/restart/shutdown/single-frame commands use the registered UDP socket.
- RecognitionState now routes controls to UDP after provisioning. BLE is unavailable as a runtime fallback once WiFi credentials are saved. useUdpVideo requires a decoded frame, while wifiConnected reflects the registered UDP peer.
- BLE text notifications now reassemble line fragments across GATT notification boundaries, retain exact ACK matching (whitespace is significant), validate fresh MAC/hostname evidence, and distinguish provisioning disconnects from the expected reboot disconnect.
- Added a live ESP32 UDP integration test that checks peer registration, status, flashlight, video frames, pause, single-frame capture, resume and disconnect.

### Verification

- Flutter transport/setup/widget regression suite: 54 passing, 0 failing; one physical UDP integration test skipped because ESP32_TEST_IP and a provisioned WiFi AP were not available.
- Targeted Dart analysis on all touched Flutter service/model/test files: clean after the final style cleanup.
- Firmware C host tests: 3/3 passing.
- Firmware Python suite: 179 passing, 0 failing.
- Firmware testbench suite: 126 passing, 0 failing.
- ESP-IDF build succeeded; firmware 3.2.0 was flashed to the connected ESP32-D0WD-V3 on /dev/ttyUSB0.
- Physical BLE test: advertising, GATT service/characteristics and CCCD verified; pairing and status worked; BLE 0x01 stream and 0x02 single-frame both returned VIDEO_AND_RUNTIME_COMMANDS_REQUIRE_UDP; zero JPEG frames were received over BLE; flashlight on/off acknowledgements passed.
- The board is in BLE setup mode with WiFi credentials erased. The laptop is on its saved Wi-Fi profile, but the tool cannot extract/replay its protected password. Therefore physical AP provisioning, UDP video throughput, AP-distance tolerance and long-run soak are still unverified. test/live_esp_udp_stream_test.dart is ready once the ESP joins the target AP.

## 2026-11-17: Physical UDP bring-up and BLE WiFi recovery

### Recovery hardening

- Added a commissioning BLE fallback when saved WiFi credentials cannot obtain a connection for 30 seconds. BLE remains setup/status-only; the firmware still rejects BLE video/runtime commands and retains UDP as the only video/control runtime transport.
- BLE initialization failures now retry every 10 seconds instead of permanently consuming the one recovery attempt. A successful WiFi connection resets the BLE recovery timer.
- Added actual-source host tests for the recovery delay, WiFi recovery timer reset, and retry after a transient NimBLE initialization failure.

### Physical observations

- Rebuilt ESP-IDF firmware 3.2.0 and flashed only the app partition at `0x10000`; esptool hash verification passed. NVS and the partition table were not erased.
- Physical recovery path verified: after repeated failed station attempts, UART reported `operation=ble.recovery outcome=advertising mode=commissioning`; BlueZ discovered `SpectruLenPor-ESP32`, GATT characteristics/CCCD were present, pairing worked, and status/config reads succeeded.
- BLE status confirmed camera ready, 8 MB PSRAM and saved SSID `khaled ` (the broadcast SSID includes a trailing space). A corrected 19-byte WiFi credential payload was acknowledged; the ESP obtained `10.198.69.232` and logged the UDP socket bound to port 8888.
- The physical UDP path is **not verified**. The Flutter live integration test repeatedly fails at `WifiUdpVideoService.connect()` with `udpTimeout`, before requesting video. Direct UDP keepalive probes receive no response; laptop ARP resolution for `10.198.69.232` remains `FAILED`; firmware UART contains no `App peer` or UDP command execution event during those probes, despite BLE status reporting WiFi connected to that IP. This strongly suggests client isolation / station-to-station forwarding is disabled on the `khaled ` AP, although its exact setting has not been inspected.
- Consequently, real JPEG delivery, sustained throughput/FPS, packet-loss recovery, range and 60-second soak remain unverified. The live soak test is implemented but cannot progress past UDP peer registration until laptop-to-ESP traffic is allowed by the AP.

### Verification

- Firmware unittest suite: **182 passed**.
- Firmware testbench unittest suite: **126 passed**.
- Host C protocol/codec CTest suite: **3/3 passed**.
- Focused Flutter transport/setup/widget suite: **54 passed, 0 failed, 1 skipped** (the opt-in live integration test was skipped in this batch).
- Targeted Dart analysis: **No issues found**.
- Separate final live ESP UDP run: **failed at UDP peer registration** with `GlassesException(udpTimeout)`; this is an explicit failure, not a pass or skip.
- `git diff --check`: clean.

### Remaining external requirement

- Enable client-to-client communication (disable AP/client isolation or wireless isolation) on the `khaled ` access point, or use a 2.4 GHz AP that permits station-to-station traffic. Keep the laptop and ESP32 on the same LAN. Then rerun `ESP32_TEST_IP=<lease> flutter test --no-pub --concurrency=1 test/live_esp_udp_stream_test.dart` to verify peer registration, real JPEG decode, pause/single-frame/resume, 60-second soak, FPS, throughput and reconnect.
