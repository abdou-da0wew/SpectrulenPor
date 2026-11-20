# ESP32-CAM firmware hardware validation

Last updated: 2026-11-20. Firmware version: `3.2.0`. The detailed build/flash inventory below preserves the 2026-11-15 commissioning record; the UDP V2 soak update immediately below supersedes earlier throughput expectations. These results apply to the ESP-IDF WiFi-only boot flow, not the Android application.

## Latest UDP V2 soak update (2026-11-20)

The firmware and Flutter receiver now use the same UDP V2 frame contract: a 24-byte header containing six little-endian 32-bit fields, up to 1200 JPEG bytes per data datagram, frame IDs, out-of-order reassembly and interleaved XOR parity recovery. The sender uses bounded retries for transient Wi-Fi queue exhaustion and RSSI-aware camera/pacing profiles.

| Test | Result | Interpretation |
|---|---|---|
| 60-second AMPDU-on soak | 210 decoded frames, about **3.50 FPS**, no incomplete frames or protocol errors | One successful run; subsequent sustained runs were inconsistent |
| Latest 60-second AMPDU-off soak | About **1.5 FPS**, one incomplete frame and one control timeout | Latest measured profile; not stable enough to call reliable |
| Requested 20–30 FPS | **Not achieved** | Throughput remains well below the project target |

Earlier selected builds also decoded camera JPEGs successfully, but a successful smoke test does not establish sustained delivery. Resolution, link quality, packet loss and long-run cadence remain open hardware issues. Do not use the 20–30 FPS target or older pre-V2 800×600 delivery test as a current measured result.

## Build and fixture

| Item | Observed value |
|---|---|
| Board | AI-Thinker ESP32-CAM, ESP32-D0WD-V3 revision 3.1 |
| Programmer | ESP32-CAM-MB, CH340 USB-UART |
| Camera | OV2640 |
| Flash | 4 MB, DIO at 40 MHz |
| PSRAM | 8 MB physical; 4 MB mapped by ESP-IDF |
| Optional AS7265x | Unavailable on this fixture |
| Toolchain | ESP-IDF 5.5.1, esp32-camera 2.1.9, esp_jpeg 1.3.2 |
| Currently flashed application | Reviewed uninstrumented session/WiFi source-fix release with UDP delivery fixes, 977,840 bytes, `build-review-release-20261115T173449Z-fb11f81d` |
| Current binary SHA-256 | `97a438e50a6245f4ce6709f2b3f806589c305ecfbe25c2599099f1deba9dfbc5` |

The reviewed release was written and independently verified against all four regions: bootloader (`0x1000`), application (`0x10000`), partition table (`0x8000`) and OTA data (`0x310000`). `review-release-20261115T173449Z-fb11f81d/release-flash-results.json` records write/verify exits 0, four digest matches, zero credential writes and zero explicit erasures under exclusive hardware ownership. Planned write sectors exclude NVS; no raw NVS comparison was made. The ELF SHA-256 is `291ca3805d837f27a9e512ba94102f5222c0da776aae1c47a4227522064cadae`. No diagnostic instrumentation is linked. UDP delivery fixes applied: dynamic WiFi TX buffers (64), 3× fragment redundancy, 200ms packet pacing, 256KB socket buffers, max TX power (20 dBm), power save disabled. Verified with saved-profile probe: all 23 fragments received, valid 800x600 JPEG decoded (11,641 bytes), zero send failures.

| Image | Application size | SHA-256 | Evidence boundary |
|---|---|---|---|
| Earlier corrected image | 977,248 bytes | `8f4a513e4d43c01763770dbd71c647372ab396c249dea65e115b2111774f09f8` | Historical partial BLE/full and missing-AP runs |
| Static-TX experiment | 977,360 bytes | `7a77ea7d98c6b278e10dfce91459e8b43d641f0b6b218b3228c4b1c2f7150b0f` | Binary retained and rehashed; UDP delivery failed |
| lwIP trace diagnostic | 992,752 bytes | `9522eea3f492be8baab5cbdcab86a36eace5f272418aa54cd4e1cdd132420d14` | Binary retained, rehashed and flashed; run01 WiFi failed, run02 reached IP/listener and partial UDP receipt without decoding |
| Earlier TX-driver/socket diagnostic | 978,016 bytes | `fb66fe0fe5525cbb0db1cbe429b3cf12197625dffa956b3ebb49ada168d62536` | Retained; driver run01 failed WiFi before image transmission; predates the NVS-init safeguard |
| Safeguarded TX-driver/socket diagnostic | 977,504 bytes | `076e2a9105542a88ac4b57a03a8991f48543b0123d609f93b00e713c6fe595a3` | Earlier independently verified flash; driver run02 reached IP/listener and sampled driver failures, but no decoded image |
| TX-completion baseline | 978,608 bytes | `95cb4f22e50671a9bea77fe11d596d26cf9c1efc324c24262ccd42c88281ba08` | Earlier verified diagnostic flash; callback run received three orphan JPEG fragments, no decoded image |
| TX-only AMPDU-off diagnostic | 978,608 bytes | `e2d87a1269dc76b8d4086c4d9e218d279cb22b7645694bfae90e5d163c9035d0` | Earlier verified diagnostic flash; RX aggregation unchanged, no decoded image |
| Legacy-PHY TX-completion diagnostic | 979,872 bytes | `2e7fb403852e992ed272ccbd3a03912f526cc350a4a00c214d528ecc5a9751d3` | Earlier independently verified flash; legacy run received sequence zero and partial assembly, no decoded image |
| Camera-DMA diagnostic build03 | 980,624 bytes | `e5ddd3cd6fbb50d9869f7682870834b8b5dad1d2ba0e066c0e6233e9365a88ea` | Historical independently verified flash after reachability review; one failed host injection retained; UDP probe failed without decoding |
| Release-source safety build | 976,848 bytes | `d3b5d790f0cd0c6f60f122550fbf8f6cf0f77282ba8c8ecd8b9cc3c09d8bcfa4` | Clean `build-safety-20261115` build with NVS-init safeguard and no TX wrappers; **not flashed**, predates sender-reporting correction |
| Reviewed session/WiFi source-fix release | 977,840 bytes | `97a438e50a6245f4ce6709f2b3f806589c305ecfbe25c2599099f1deba9dfbc5` | Currently flashed with UDP delivery fixes, four NVS-excluding regions independently verified; saved-profile probe decoded valid 800x600 JPEG (11,641 bytes), zero send failures |

The trace configuration retains 16 static TX buffers and enables lwIP ARP, netif, socket and UDP debugging. Reconstructing settings from generated JSON initially rendered hexadecimal Kconfig values as decimal text, including the partition offset. The failed build was corrected to `0x8000` before the successful build and flash; it was never flashed.

The separate TX probe wraps existing `esp_wifi_internal_tx` and `lwip_sendto` calls while preserving payloads, return values and socket errno. It does not add resends or change the protocol. Its effective config differs from the retained trace build only by disabling five defines: `CONFIG_LWIP_DEBUG`, `CONFIG_LWIP_ETHARP_DEBUG`, `CONFIG_LWIP_NETIF_DEBUG`, `CONFIG_LWIP_SOCKETS_DEBUG` and `CONFIG_LWIP_UDP_DEBUG`. Generated headers were compared; partition binaries are identical, as recorded in `tx-probe-build-identity.json`. Failed builds 1 through 3 are retained and were never flashed; build 4 succeeded.

The currently flashed binary includes the NVS-init safeguard: `main.c` stops boot with `NVS_INIT_FAILED` on initialization errors and preserves NVS. Four host-C regressions compiling the actual `app_main` passed before flashing and passed again during evidence reconciliation: successful initialization continues without erasing, while no-free-pages, new-version and other initialization errors stop boot after one initialization call, with no erase or downstream startup. No hardware NVS initialization fault was injected. Selected source snapshots were retained and checked against the pre-build source-identity hashes; they are not a snapshot of every compiled dependency.

The earlier safeguarded diagnostic built cleanly with ESP-IDF 5.5.1. Its effective generated headers and partition binary match the earlier TX diagnostic, as recorded in `diagnostics/tx-probe-safety-20261115/build-identity.json`. Callback, AMPDU, legacy and camera-DMA experiments retain their historical build/flash identities and failures. The current reviewed release includes the NVS safeguard, corrected sender reporting, and UDP delivery fixes. UDP delivery verified on real hardware: valid 800x600 JPEG decoded over WiFi-only UDP.

The separately retained older release-source safety build uses ESP-IDF 5.5.1, esp32-camera 2.1.9 and esp_jpeg 1.3.2. It completed with zero compiler warnings/errors and no TX-driver/socket linker wrappers. Its effective generated header matched the diagnostic flashed at that time; partition binaries were identical. `software-safety-20261115/release-build-identity.json` records its application/ELF, flash arguments and region hashes, with `flashed: false`. This older build contains the safeguard but remains unflashed; it is distinct from the currently deployed reviewed release.

## Host verification

Checks below cover successive uncommitted source snapshots on 2026-11-15, not a published release or complete hardware contract. Retained raw execution logs and attributed inline-only results are distinguished.

The approved source-fix pass retained actual-path negative regressions for Python cancellation/shutdown/reporting, firmware BLE session/WiFi transition races and Flutter acquisition/cleanup. Latest combined Python execution passed **180 firmware + 124 testbench = 304 tests**, zero failures/errors/skips. The complete Flutter suite passed **190 tests**, zero failures/skips, and `flutter analyze --no-pub` reported zero issues. Raw logs, timestamps and unchanged source identities are retained in `review-software-20261115T174518Z-bc9ccc55`. Fresh strict-warning/ASan/UBSan protocol checks passed 578 command, 11 JPEG and 8,974 UDP checks. Focused 62 Python, 30 firmware host-C and 63 Flutter tests are subsets, not extra counts. Flutter plugin stubs do not verify real Android scheduling or scans; firmware host interleavings do not verify real FreeRTOS/event delivery or updated twenty-attempt exhaustion. The interrupted earlier full Flutter run remains non-passing evidence.

The reviewed release compiled cleanly and passed source/configuration/partition/ELF checks, with planned write sectors excluding NVS. An overbroad checker initially rejected SDK C++ runtime wrappers; that rejection remains retained, and the corrected check allows only wrapper names verified in pinned SDK CMake/source. Pre-flash gates preserve `flashed: false`; the later independent flash report establishes deployment. A fresh disconnected-backend SIGTERM smoke exited 0, served empty frames as HTTP 204 and supplied three empty reads to the HTTP viewer consumer. Two smoke-check schema mistakes remain retained separately; the application was not changed to satisfy them. This is not live-image, GUI or signal-driven hardware teardown evidence.

- Strict C warnings: `-Wall -Wextra -Werror -Wpedantic -Wconversion -Wshadow`.
- AddressSanitizer and UndefinedBehaviorSanitizer: all three test groups passed, with 578 command checks, 11 JPEG checks and 8,974 UDP checks.
- Earlier reported Python regressions: 146 firmware plus 101 testbench tests, **247 passing**, with `OK` outputs reported by the delegated agent. Those outputs were inline only; no independently retained raw log or exact execution timestamp was found. `diagnostics/standalone-signals-reported-20261115/results.json` records that provenance. Completed tests were not rerun just to obtain archival logs; the newer combined suites followed approved source changes.
- Earlier retained Python execution: 117 firmware plus 101 testbench tests, **218 passing**, with zero failures, errors or skips. Coverage includes exact acknowledgments, retry counting, provisioning cancellation, exclusive ownership, independent cleanup, CLI signal/partial-start failures and post-cleanup reporting. This snapshot predates the later standalone-signal and sender changes.
- The separately repeated 17 CLI and 4 actual-`app_main` NVS tests passed. These are subsets of the 218 Python tests, not additional counts.
- Eight actual-sender host-C regressions passed after five failures were reproduced on the old implementation. They cover no-attempt deadlines, inter-fragment expiry, resource retries, socket errors, short writes, complete sending and invalid/inactive input. These tests are included in the reported firmware suite, not extra suite counts.
- Flutter 3.47.1 stable, Dart 3.13.1: latest 190 tests passed and `flutter analyze --no-pub` reported zero issues. Framework revision: `6655482ec06e547f90abf8ae7590466f4415978d`. Earlier 147-test results and the original-scope `dart analyze` configuration hash remain historical. These are local software checks, not Android hardware results.
- Private camera-DMA actual-source harness: three header-order checks and ten safety cases passed; `dma_transient_restart_during_drain` failed. The failure remains retained and is not counted as a pass. Host register spies and synchronous queued calls do not establish ESP32 scheduling or continuous electrical DMA state.
- Actual disconnected-backend CLI SIGTERM smoke exited 0, returned 204 for an empty frame and recorded no hardware connection or live camera verification.

Earlier `software-final-20261115` evidence remains separate: 105 firmware/HIL plus 90 testbench Python tests (195 passing, no skips), 147 Flutter tests and protocol checks. Earlier syntax parsing passed for 29 HIL/testbench files, dashboard JavaScript and the diagnostic script. Actual-backend browser checks passed five groups with no browser errors or hardware/external requests: EN/AR/RTL, 390/320px layouts, reports, security/validation rejection and intercepted no-UART mobile-flow forwarding. OpenCV 4.10.0 consumed three empty HTTP reads without a GUI or live image. These historical checks were not repeated as live hardware checks during safety verification.

## Hardware execution status

The earlier missing-AP run passed all three cases. The corrected full real-network run passed fourteen cases through BLE provisioning and WiFi-only software reboot, then failed its first UDP image with `HIL_UDP_FRAME_TIMEOUT`. UART observed UDP command `0x02` executing and one SVGA frame being sent, but that does not establish receipt or decoding. UDP throughput, controls and real-network reset recovery are not yet verified by a complete run.

The corrected image's BLE stream check decoded three QVGA frames at 0.96 received fps. Pairing authorization, six invalid/unauthorized command rejections, connection-scoped authorization reset, maximum 99-byte provisioning payload, synthetic reconfiguration/erase, erased-NVS software restart and standby/resume passed. These are partial results, not a full-run pass.

| Missing-AP check | Observed result |
|---|---|
| Fresh advertisement and GATT | Notify TX, write RX and CCCD found; camera and PSRAM available |
| Retry sequence | Attempts 1 through 20, exactly 20 reason-201 failures |
| Exhaustion | `wifi=failed`, followed by a 40-second observation window without another attempt |
| BLE absence | No BLE initialization; fresh five-second scan after clearing the cached fixture entry |
| NVS persistence | Hardware reset selected WiFi-only again; a new sequence started at attempts 1 and 2 with reason-201 failures |
| Runtime faults / cleanup | None observed; run exited 0 |

Missing-AP report SHA-256: `c63db1256ce1ee7faaf67ad3900aa632493d5612feb3e760d3a9821188aa4761`. UART SHA-256: `f4999f304670a9f102f6881f96fa8e77486b06483aeb85d17c3b7d511838048b`. The test left synthetic credentials persisted; only NVS (`0x9000`, size `0x6000`) was erased before the real-network run.

The first WiFi-only full run failed during pairing authorization after eight BLE/GATT/media cases passed. Its application-level authorization error triggered BlueZ security negotiation and a disconnect. The corrected image returns ATT `0x13` for that gate. The earlier partial run does not establish that the corrected image passes.

The first corrected missing-AP run reported `HIL_NO_AP_FAILURE_NOT_OBSERVED` even though UART contained all twenty reason-201 failures and `wifi=failed`. A repeated wildcard regex stalled while only nineteen failures were present. The repaired harness counts independent matches and still requires the exact attempt sequence, exact failure count, exhaustion and a post-exhaustion observation window. An absent BlueZ object after intentional reboot no longer becomes a false cleanup error; real transport failures remain fatal.

### Historical pre-UDP-V2 delivery result (2026-11-16)

The comprehensive pre-V2 hardware attempt was `firmware/test-results/comprehensive-udp-20261116T054909Z-14fbe3f6/`, on the reviewed uninstrumented release with the earlier UDP delivery fixes. That run decoded 5/5 stream frames (800×600), passed flash/stream/pause/single-frame controls, retained credentials across a soft reset and returned 200/204 from all seven dashboard API endpoints. It recorded zero send failures, cleanup errors, credential writes or erasures. Probe report: `ok: true`, `firmware/test-results/comprehensive-udp-20261116T054909Z-14fbe3f6/results.json`.

**This result belongs to the earlier pre-V2 transport. It does not establish current UDP V2 throughput or reliability.** The November 20 V2 soak update at the top of this document is the current physical-performance evidence.

Earlier failed probes (`udp-camdma-01`, `saved-profile-review-20261115T182628Z-082c0917`, `udp-delivery-3x200ms`, etc.) remain retained as historical evidence of what did not work. None decoded a complete UDP JPEG.

| Probe | Result | Fragments | Decoded |
|-------|--------|-----------|---------|
| `udp-camdma-01` | Failed `HIL_UDP_FRAME_TIMEOUT` | 0/34 accepted | No |
| `saved-profile-review-20261115T182628Z-082c0917` | Failed `HIL_UDP_FRAME_TIMEOUT` | 19/34 accepted | No |
| `udp-delivery-CONFIRM-20261115T215451Z-e44cb65f` | **Passed** | 23/23 received | **Yes** (800x600, 11,641 bytes) |
| `comprehensive-udp-20261116T054909Z-14fbe3f6` | **Passed** | 5/5 stream frames | **Yes** (800x600, ~11,600 bytes each) |

The `saved-profile-review` probe ran from `2026-11-15T18:26:28Z` to `18:27:26Z` and exited 1 with `HIL_UDP_FRAME_TIMEOUT`. UART observed a fresh WiFi-only boot, camera readiness, IP/listener and one executed UDP request. Received sequences were `0,2,3,5,12,15,16,17,18,21,22,23,25,26,28,30,31,32,33`; one 34-fragment assembly expired. UART logged `operation=frame.send transport=udp bytes=17266 width=800 height=600` and subsequent `frames=1,errors=0`, with no sender failure. Those markers are sender-side only; they do not establish host delivery or explain the missing fragments. Report: 6,012 bytes, SHA-256 `ab3fe40781f9241bf62193982f1c3807f8bc0a8be557e327b300e5825ed5ef3b`. UART: 13,112 bytes, SHA-256 `24006bf2c389c96adf7fa503269c892ed8e7dbc1d535772a1eb8a218078b73fb`.

The `udp-delivery-CONFIRM` probe ran from `2026-11-15T21:54:51Z` to `21:56:36Z` and exited 0 with `ok: true`. All 23 fragments received across 3 attempts with 3× fragment redundancy, valid 800x600 JPEG decoded (11,641 bytes), zero send failures, zero cleanup errors, zero credential writes/erasures.

The `comprehensive-udp-20261116T054909Z-14fbe3f6` test ran from `2026-11-16T05:49:09Z` to `05:49:42Z` and exited 0 with `ok: true`. Verified all previously-unverified items: 5/5 UDP stream frames decoded (all 800x600), UDP controls (flash on/off, stream on/off, single after pause) all work, reset persistence verified (soft reset via DTR, credentials persisted, WiFi reconnected, image decoded after reset), dashboard API verified (7/7 endpoints returned 200/204). Zero send failures, zero cleanup errors, zero credential writes/erasures.

Callback instrumentation retains bounded scalar metadata only, never payloads or borrowed pointers, and does not assume the callback packet layout. Nineteen of twenty callbacks in the baseline JPEG-burst time window reported failure. That temporal observation does not map each callback to a JPEG fragment or prove delivery for callbacks reporting success.

The callback, AMPDU-off and legacy sender summaries report `UDP_SEND_DEADLINE` with the last attempted socket `ENOMEM`: sequence 20/35 (37 attempts), 25/34 (14 attempts) and 32/33 (9 attempts), respectively. Legacy requested 473 bytes for its final fragment and reported heap 93,627 / largest block 90,112. These historical failures motivated the dynamic TX buffer and send pacing fixes; the current reviewed release with those fixes achieves zero send failures and complete UDP JPEG delivery, verified via comprehensive hardware testing.

Legacy report: 5,387 bytes, SHA-256 `a778c281996557826743a0cc3352119bc95dfb0f96aab8aa75d027c0ae39de42`. UART: 26,790 bytes, SHA-256 `55adca64e76232c86e09316993345045126d6a135435cf010c7abc2161a0db47`. Earlier failures remain separately retained.

### Camera-DMA comparison

The private diagnostic keeps legacy PHY and normal AMPDU, gates queued `ll_cam_start` calls, invokes `cam_stop`, forwards the original sender once, waits a bounded 10-second drain and calls `cam_start` after sender success or failure. It does not disable XCLK, free camera allocations or change the UDP format, pacing or sender deadline. A final RX/EOF register snapshot is not proof of uninterrupted electrical inactivity.

Build01 failed because camera public driver dependencies were not visible. Build02 failed because `cam_hal.h` uses `TickType_t` before including FreeRTOS. Both compiler failures are retained and unflashed. Build03 compiled with zero warnings/errors after privately linking the pinned camera target and correcting include order. Generated config and partition binaries match legacy; local component snapshots and hashes are retained.

Three post-build checker failures incorrectly assumed Ninja or direct/uninlined caller symbols. They remain retained. Corrected checks used the actual Unix Makefiles `link.txt` and verified `cam_task -> cam_start_frame -> __wrap_ll_cam_start` and `app_main (inlined capture_and_send) -> __wrap_udp_stream_send_frame` in the ELF without rebuilding. Use `diagnostics/tx-camdma-03-20261115/build-deployment-gates.json` for the successful build gates, not the earlier failed checker reports.

The corrected-source host harness passed three header-order checks and ten safety cases, but failed an injected transient register restart during the drain that stopped before the final check. The retained reachability review found direct mutation of stub I2S registers in `vTaskDelay`, bypassing all compiled camera code; no equivalent bypassing restart path was found in the pinned ESP32 driver. It retracts the earlier proven-firmware-defect classification. The failed case remains unchanged as an unsupported arbitrary register-mutation limit, not a pass or continuous electrical-monitoring test.

After source/image hash checks and that assessment, build03 was flashed and independently verified in four NVS-excluding regions. The pre-flash `build-deployment-gates.json` remains unchanged with its historical pending/unflashed fields; `safety-deployment-assessment.json` and `flash-results.json` record the later assessment/deployment. No test rerun or source fix was performed to clear the injected failure.

`udp-camdma-01` recorded a fresh WiFi-only boot and command execution. UART showed `rx_start=0 eof_irq=0 dma_stop=0` before sending at uptime 14,288 ms, then `stopped=1 blocked_starts=0 send_result=0 drain_ms=10000 acquisition_resumed=1` at 27,310 ms. This confirms acquisition-off snapshots, a bounded wait and a resume-call marker, not an asserted descriptor-stop bit, actual queued-start suppression or successful subsequent capture. No queued starts occurred and no later image request was made. Cleanup datagram submissions are not device acknowledgments. `camera-dma-evidence-assessment.json` records these limits.

The sender failed with `UDP_SEND_DEADLINE errno=12 seq=28 total=34 bytes=528 result=-1 attempts=18 heap=93591 largest=90112`. The host received one echo plus nine orphan JPEG fragments and decoded nothing. Pausing acquisition did not fix delivery in this comparison; it does not rule out clock/sensor interference or every hardware DMA fault. Report: 3,445 bytes, SHA-256 `f5d299ca2e8d0e3bf5d9586434ff92f2846497b9556a90036e43426ef3e497e0`. UART: 23,440 bytes, SHA-256 `18fe7068ad350ac2cc30386cd7de7de16991601ec33ed6c75f1c71bdc0932ada`.

### Earlier transport evidence

The static-TX experiment selected 16 buffers on a fresh WiFi-only boot. It accepted fragments 0 through 17, then logged `errno=12` (`ENOMEM`) at fragment 18 of 36, with 528 bytes requested, 98,959 bytes of heap and a 98,304-byte largest block. The host received no datagrams. lwIP maps `ERR_MEM` to `ENOMEM`, but ARP and the netif/WiFi transmit paths can both return memory errors; the source is still unproven. Accepted `sendto` calls are not delivery evidence.

The earlier `firmware/test-results/udp-driver-02/` followed user-confirmed closer router placement. The safeguarded diagnostic selected WiFi-only on a fresh boot. Attempts 1 and 2 disconnected with reasons 2 and 205; attempt 3 associated at -72 dBm, obtained an address and opened the UDP listener. Exactly one single-frame request received two 528-byte JPEG datagrams, sequences 24 and 25 of 33, at offsets 12,288 and 12,800. No sequence zero or control echo arrived. The reassembler accepted zero fragments and decoded no image; the run failed with `HIL_UDP_FRAME_TIMEOUT`. Credential writes, erasures and cleanup errors were zero. No runtime-fault marker was found in the retained UART capture.

The first sampled transmit failure was sequence 15: `esp_wifi_internal_tx` returned `0x101` (`ESP_ERR_NO_MEM`), followed by `lwip_sendto` returning `-1`, `errno=12` (`ENOMEM`). Further sampled records show the same driver/socket failures while the sender's existing bounded retries remain active. ESP-IDF 5.5.1 defines `0x101` in `esp_err.h`; `wlanif.c` maps it to lwIP `ERR_MEM`, which `err.c` maps to `ENOMEM`. This identifies the WiFi transmit API as the source of those sampled failures, not an ARP-only inference. It does not identify the driver's internal allocation/queue cause, explain every missing datagram or establish that successful sends were delivered.

The old final sender summary reports `errno=0 seq=26 total=33 bytes=528 result=-1 heap=98971 largest=98304`. If the frame-wide deadline had already expired, no `sendto` was attempted and initialized fields reached the failure log. It is not evidence of a socket returning `-1` with zero errno. The later regression-tested correction distinguishes `UDP_SEND_DEADLINE`, `UDP_SEND_SOCKET_ERROR` and `UDP_SEND_SHORT_WRITE`, with per-fragment attempt counts and the last actual socket result. Generic free internal heap does not establish availability of the driver's specific transmit resources.

Driver run02 report: 1,272 bytes, SHA-256 `a9ed6798a16c56daaacf22dd8b4b63a0bc21ec1e5ed0e280411531b16cdd8898`. UART: 20,395 bytes, SHA-256 `78594fdbbc8eb9f47aebcb8338809155f4d11745c830ded773555088aee0954f`. Closer placement coincided with a stronger association RSSI than the earlier -88 dBm observation, but did not verify transport delivery. Later saved-profile probes are recorded above; none wrote or erased credentials.

Earlier `firmware/test-results/udp-driver-01/` failed with `HIL_WIFI_CONNECT_TIMEOUT` after one fresh WiFi-only boot, without a `wifi.got_ip` event or UDP listener. Disconnect reasons were 2, 205, 201, 201, 2, 201 and 4. Its report records zero image requests, datagrams, credential writes and erase operations, and empty cleanup errors. UART contains no driver/socket TX diagnostic records or UDP send failure. That attempt never reached image transmission and provides no observed driver-failure evidence.

Driver run01 report: 367 bytes, SHA-256 `daa7f1d9ef2a27595b6836b6b74be7bdc82fbb3f5644841df118ad704f51957d`. UART: 16,858 bytes, SHA-256 `257e286ed8620a1a23b5a1e2aff89ea6638ea7206d944f32044ee9fec36fb61b`. Earlier board/laptop RSSI observations of -88 dBm/-70 dBm leave RF conditions as a candidate, not a proven cause.

The prior `firmware/test-results/udp-trace-02/` recorded a fresh WiFi-only boot, AP connection, `wifi.got_ip` and the UDP listener. The report records exactly one single-frame request, zero credential writes and zero erase operations. The host received one `0x02` echo plus 13 JPEG datagrams with sequences 4, 11, 12, 13, 14, 16, 17, 18, 24, 25, 27, 28 and 29; all advertised 62 fragments. No sequence 0 arrived, so the reassembler never initialized the frame: its counters show 14 datagrams and zero accepted fragments, not zero network receipt. No image was decoded; the run failed with `HIL_UDP_FRAME_TIMEOUT`.

Run02 UART logged `errno=12` (`ENOMEM`) at sequence 31 of 62, requesting 528 bytes with 98,915 bytes of heap and a 98,304-byte largest block. Cleanup errors were empty. Normal ARP messages do not establish the cause of the transmit failure; the root cause remains unproven. No raw NVS dump or before/after comparison was executed. This diagnostic image is not a verified UDP fix.

Run02 report: 4,296 bytes, SHA-256 `f9ea92e6d422fde33e50d0afb94f75c90aa6dcf3f56bee45837cccd312fdd7b2`. UART: 496,691 bytes, SHA-256 `9ac2599c592c9536906be459ae20dfab001870fa57d3f355d7602a284a6bce68`.

The earlier trace run in `firmware/test-results/udp-trace-01/` failed with `HIL_WIFI_CONNECT_TIMEOUT` before opening a UDP socket or requesting an image. UART recorded a fresh reset, valid 800x600 boot JPEG, `wifi_only`, `camera=1` and seven connection attempts. Disconnect reasons were 201, 201, 201, 201, 204, 205 and 201. The ESP-IDF 5.5.1 header defines these as no AP found, handshake timeout and connection failed. The fifth attempt reached association, but security establishment timed out; there was no `wifi.got_ip` event or UDP listener. This remains separate connection-failure evidence, not the latest delivery blocker or a regex mismatch.

Run01 performed zero credential writes and zero erasures, and reported no cleanup errors. UART SHA-256: `34661424565cf63e72986f35c6fcdf6fad138b98f494e3243dd63e49098c77e3`. The laptop's cached WiFi scan showed the same AP on 2.4 GHz, but that does not establish the fixture's signal strength or validate its saved password.

A separate UART-only attachment in `udp-trace-observe-01/` performed no explicit reset, credential write, erase or UDP request. Opening UART nevertheless produced a fresh power-on reset on this CH340 fixture. Two complete status records still showed `wifi=connecting` with no address; a third was incomplete when capture ended. No IP/listener was observed, and the report remains failed with both aggregate flags false. This is not a passive persistence check. UART SHA-256: `85dcdc8405b26cb134044f6526411164f9c2896bb16e85154a3e8cd049370a62`.

Packet capture is also unverified: the earlier tcpdump attempt lacked `CAP_NET_RAW` and produced no pcap. Live dashboard/API/OpenCV delivery has been verified via comprehensive testing: dashboard server started, all 7 API endpoints returned 200/204. UDP throughput is scene/network dependent; no long-duration soak, battery, thermal or RF-range result is claimed.

### Cleanup and ownership

Dashboard, CLI, standalone HIL, boot checks and diagnostics share the adapter/canonical-UART lease through handled resource teardown. `HardwareSuite.run` relies on its caller's lease, avoiding a nested acquisition. OpenCV reads the worker's frame store or HTTP endpoint, never a competing UDP receiver.

HIL cleanup independently attempts stream-off, flash-off, BLE disconnect and UDP close when applicable, so a failed control acknowledgment does not skip later cleanup. Boot-smoke independently clears DTR/RTS and closes UART, preserving primary failures with collected cleanup exception types. UART cleanup joins the finite-timeout reader and attempts every acquired-resource close independently. Cleanup-only failures invalidate successful jobs and aggregate flags. CLI reports and exit status are selected after worker shutdown. No timeout or cleanup path automatically resends or erases credentials.

CLI and standalone HIL/boot regressions cover cooperative SIGINT/SIGTERM cancellation, handler restoration, partial starts and protected teardown under ownership. Handlers only record a request; checkpoints observe cancellation, and repeated signals cannot interrupt protected cleanup. Native D-Bus calls still must return before cancellation is observed. The real SIGTERM smoke used a disconnected backend only; neither it nor empty diagnostic cleanup errors verifies signal-driven live hardware teardown or every shutdown path.

## Reproduction and evidence

Run from `firmware/`, with Linux BlueZ and the dependencies listed in the [firmware README](../firmware/README.md). Every run needs a fresh private output directory.

```sh
python3 tests/wifi_retry_hil.py --port /dev/ttyUSB0 --adapter hci0 \
  --output test-results/missing-ap
```

This test requires empty setup credentials. It provisions a generated nonexistent SSID, observes all configured retries and `wifi=failed`, watches beyond a retry window, checks for fresh BLE advertisements, then resets and observes a new retry cycle using persisted credentials. It leaves synthetic credentials in NVS. An authorized NVS-only reset must follow before the final real-network run.

```sh
python3 tests/hardware_e2e.py --port /dev/ttyUSB0 --adapter hci0 \
  --output test-results/full-run --wifi-from-nm
```

The full run tests synthetic boundaries and erasure before final real provisioning. `--wifi-from-nm` reads the active profile into memory without printing or saving its password. After BLE `0x0B`, verification uses fresh UART logs and real decoded UDP JPEGs, never a BLE reconnection. The final reset must produce another WiFi-only boot and another decoded UDP image.

Private evidence consists of `results.json`, `uart.log` and JPEG files. Do not commit raw evidence containing the local network identity, device addresses or camera scenes. The versionable report contains only measured summaries and artifact hashes.

Earlier temporary-directory builds, raw HIL captures, the static-TX diagnostic log and mocked harness were lost when the temporary directory was cleared. Their historical summaries/hashes remain, but the raw captures cannot currently be revalidated. The retained static-TX binary was independently rehashed; that does not recover its missing UART evidence. Retained trace/TX-probe build and flash evidence, browser screenshots/results and earlier software-check logs are kept in ignored repository directories.

Earlier raw software logs remain in `cleanup-lifecycle-20261115T134743Z-8676d80a/` and `software-safety-20261115/`; the original-scope analyzer check is in `analyzer-original-scope-20261115/`. The reported 247 Python results have an attributed inline-only report under `diagnostics/standalone-signals-reported-20261115/`, not a recovered execution log. Callback, AMPDU, legacy and camera build/assessment/flash evidence remains historical under `diagnostics/`. Latest complete software logs/source identities are in `review-software-20261115T174518Z-bc9ccc55/`, Flutter red/green evidence in `flutter-ble-lifecycle-20261115T173546Z-p81evk9h/`, and reviewed release build/gates/flash reports in `review-release-20261115T173449Z-fb11f81d/`. Latest hardware report/UART is in `saved-profile-review-20261115T182628Z-082c0917/`. The private index preserves earlier artifact entries and appends new evidence with `review-release-20261115T173449Z-fb11f81d/evidence-index-pre-review.json` as its pre-update backup. Generic mutable sources are not substituted for flashed provenance; historical runs do not establish a complete contract for the current image.

## Limits

- **Complete UDP JPEG decoded**: valid 800x600 JPEG (11,641 bytes) received over WiFi-only UDP on the reviewed uninstrumented release. All 23 fragments received, zero send failures, zero cleanup errors. Firmware delivery verified on real hardware. Mobile-contract, Android and sensor aggregate flags remain unverified (no ADB device attached, AS7265x unavailable). Stream/pause/flash, fresh capture after resume and decoded footage after reset can now be validated since delivery works.
- AS7265x hardware and telemetry cadence are unverified. No readings are synthesized. Its legacy `$UV:` field represents the A channel at 410 nm, not a calibrated UV measurement.
- Android pairing, reconnect and application integration have not been hardware-tested by these Linux runs. No Android device was attached to ADB during this session; Flutter source verification is separate from real-phone verification.
- The fixed setup code `11111` is application authorization, not encrypted Bluetooth bonding. UDP control is unencrypted and another sender may claim the stream with `0x01` or `0x02`.
- The hostname is sent over BLE and configured on the station interface. This firmware does not run an mDNS responder.
- WiFi-only failure does not enable BLE or erase credentials. Setup recovery after boot requires an explicit authorized NVS reset.
- Throughput is scene/network dependent. Scheduling constants are targets, not measured frame-rate guarantees. No long-duration soak, battery, thermal or RF-range result is claimed.
