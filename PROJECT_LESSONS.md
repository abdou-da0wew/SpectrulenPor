# Project lessons

2026-11-15: [Architecture] ESP32-CAM commissioning requires BLE setup followed by WiFi-only boot -> save the credential blob in NVS without initializing WiFi, then use paired 0x0B to reboot; valid credentials select WiFi-only even when the AP is unreachable -> verify boot mode through fresh UART evidence and confirm BLE absence with a cache-cleared scan.

2026-11-15: [Error Handling] ATT insufficient-authentication made BlueZ negotiate SMP security for an application setup code and disconnect -> use ATT value-not-allowed for this gate; transport errors must not count as rejected commands -> require exact BlueZ rejection messages and a live status query after each rejected write.

2026-11-15: [Testing] Provisioning tests mutate the fixture -> keep synthetic boundary/reconfiguration/erase checks before final real credentials, run missing-AP exhaustion separately, reset only authorized NVS, and finish with real provisioning -> inspect phase order, NVS persistence after reset and an actual decoded UDP image.

2026-11-15: [Testing] The attached fixture has an OV2640 and PSRAM but no available AS7265x -> report sensor checks as unverified and emit no fabricated readings; the legacy UV field is a 410 nm spectral channel, not calibrated ultraviolet data -> inspect UART sensor availability and reject unexpected sensor notifications.

2026-11-15: [Cross-Platform] Linux BlueZ testing needs system Python packages while ESP-IDF flashing needs its own virtual environment -> use the interpreter appropriate to each command and derive dependencies from the component lock -> verify imports, build identity and flash hashes before hardware execution.

2026-11-15: [Testing] A regex repeating a failure token with a wildcard twenty times stalled on nineteen matches and missed an actual retry-exhaustion result -> count independent matches with UARTLog.wait_count and retain exact final counts and sequence checks -> regression-test the nineteen-of-twenty snapshot and fragmented twentieth event.

2026-11-15: [Error Handling] BlueZ can remove the device object after the intentional setup reboot before cleanup runs -> consult managed objects, clear local authorization, and accept absent-object races only after rechecking absence -> test missing entries, object-removal races and genuine transport failures separately.

2026-11-15: [Testing] Static WiFi TX buffers did not resolve UDP delivery on the fixture: a fresh WiFi-only boot selected 16 buffers and accepted fragments 0 through 17, then failed with ENOMEM at fragment 18; the host received no datagrams -> keep the experiment separate from a verified fix and preserve credentials while checking the transmit path -> require fresh association/listener evidence and an actual decoded image, not successful sendto calls.

2026-11-15: [Error Handling] Cancelling Flutter setup during an in-flight credential write invalidated the generation before the catch block could mark uncertainty -> mark configuration uncertain before awaiting the credential write and clear it only on current-session confirmed success -> regress disconnects during both pairing and provisioning, including late replies and absence of preference writes.

2026-11-15: [Testing] The trace image's WiFi probe failed before any UDP request, with disconnect reasons 201/204/205 and no got-IP/listener evidence -> distinguish association/security failure from UDP failure and preserve this failed run separately; laptop AP visibility does not validate the fixture's password or RF link -> compare raw UART events against the installed ESP-IDF reason definitions before changing evidence matching or reprovisioning.

2026-11-15: [Testing] Opening UART on the CH340 fixture caused a fresh reset even with no explicit reset call and DTR/RTS initially false -> count observed boot/reset evidence and classify attachment captures as intrusive when necessary, never as passive persistence checks -> reject an observation-only persistence claim whenever a fresh reset appears.

2026-11-15: [Error Handling] Cleanup failures could invalidate HIL/dashboard success after the result was selected -> keep the hardware lease through teardown, join the finite-timeout reader, independently close all acquired resources, and choose CLI reports/exit status after shutdown -> regress partial entry, line-control failure, reader lifetime, original-error preservation and cleanup-only aggregate failure.

2026-11-15: [Testing] Temporary raw captures were lost while historical hashes and retained binaries survived -> keep new private evidence in ignored repository directories and explicitly mark lost captures as unavailable, not revalidated -> inventory artifacts and rehash retained binaries before reconciling public validation claims.

2026-11-15: [Cross-Platform] Reconstructed sdkconfig JSON converted hexadecimal Kconfig values into decimal text and caused partition overlap -> restore Kconfig hex representation before building or flashing -> compare generated headers/settings and verify the partition table offset against partitions.csv.

2026-11-15: [Testing] The credential-preserving second trace joined WiFi but received only 13 orphan JPEG datagrams and no sequence zero, then failed sending sequence 31 with ENOMEM -> distinguish received datagrams from accepted reassembly fragments; inspect the driver return before assigning ARP or heap exhaustion as the cause -> correlate socket errors with fresh driver evidence and require a decoded image.

2026-11-15: [Testing] The board reported -88 dBm at association while the laptop observed about -70 dBm -> laptop signal is not a measurement of the board's RF link; weak fixture-side reception is a candidate, not a proven error source -> retain the board's association RSSI alongside transport evidence before requesting a placement change.

2026-11-15: [Error Handling] Standard ESP-IDF sample recovery erased NVS on initialization errors despite the credential-preservation contract -> stop boot on the first failed initialization and require explicit operator recovery -> compile the actual app_main with initialization, erase and continuation spies; require one initialization call, zero erasures and no downstream startup for every failure.

2026-11-15: [Testing] Closer placement yielded -72 dBm association but driver run02 still received only JPEG sequences 24/25 of 33 -> sampled esp_wifi_internal_tx returned ESP_ERR_NO_MEM, mapped through lwIP to socket ENOMEM; report the observed API failure without assigning an internal queue/allocation cause -> correlate driver/socket records and retain failed probe evidence; stronger RSSI and accepted sends are not decoded delivery.

2026-11-15: [Error Handling] A frame-wide send deadline expired before the next fragment's retry loop and initialized result=-1/errno=0 fields reached the failure summary -> distinguish UDP_SEND_DEADLINE, UDP_SEND_SOCKET_ERROR and UDP_SEND_SHORT_WRITE with per-fragment attempt counts and the last actual socket result; eight actual-sender host-C regressions passed -> trace the actual send loop and regression-test expiry before the first send, between fragments and during retries.

2026-11-15: [Testing] Legacy PHY improved one saved-profile run to five of five ping replies and sixteen received JPEG fragments but still decoded no image -> treat the improvement as an observation, not a fix; isolate camera DMA without changing clocks, allocations, packet format or the sender deadline -> retain per-run ICMP, UART, datagrams and assembly-expiry evidence.

2026-11-15: [Cross-Platform] A private camera-DMA wrapper manually included camera headers without linking their public driver dependencies, then included cam_hal.h before FreeRTOS.h defined TickType_t -> link the pinned camera target privately and follow the HAL's required header order; retain both failed builds and never flash them -> inspect the pinned headers/dependency graph and model the TickType_t prerequisite in the actual-source host harness.

2026-11-15: [Testing] A failed host transient test directly mutated stub I2S registers and bypassed all compiled camera code -> retain it as an unsupported arbitrary register-mutation limit, not a proven reachable pinned-driver defect; the guarded external ll_cam_start path was confirmed in the ELF -> inspect the injected path, pinned register writes and actual linked callers before changing source or clearing deployment gates.

2026-11-15: [Testing] Camera-DMA pause with legacy PHY still failed UDP: 4/5 ping replies, echo plus nine orphan JPEG fragments, deadline/ENOMEM at sequence 28/34 -> do not promote acquisition pause to a transport fix; RX/EOF snapshots were zero and the resume call was logged, but blocked_starts=0 and no later capture request left hardware suppression/reacquisition unverified -> retain source/image identities, before/after UART markers and decoded-image failure separately.

2026-11-15: [Documentation] The firmware README build section retained a stale current-image paragraph after its latest-probe section was reconciled -> check all deployment statements against camera build03's independent flash report and retain earlier images only as historical evidence -> search the complete README and validation documents for present-tense fixture/current-image references.

2026-11-15: [Testing] The testbench FakeClient checks cancellation before provisioning, but the actual CooperativeBluez inherited write path does not -> test cancellation after NetworkManager returns against the real helper and mocked D-Bus write boundary; one post-cancellation provisioning write was reproduced without hardware -> compare fake checkpoints against production methods before trusting cancellation tests.

2026-11-15: [Error Handling] A CLI signal set the resettable job cancellation event before submit cleared it -> keep process interruption separate from per-job cancellation and test actual admission, not only signals injected inside fake submission -> a hardware-free real-engine reproduction acquired fake BLE and returned success after the pre-submit signal.

2026-11-15: [Error Handling] Successful job status survived a later idle receive failure and successful cleanup, leaving live ok=true, synthetic verification flags and stale saved results -> final report health must include runtime errors and persist the failure after teardown, independently of historical job success -> actual-worker regression reproduced both the live and saved inconsistency with no hardware access.

2026-11-15: [Testing] ESP-IDF release ELF/link commands include SDK C++ runtime wrappers even without diagnostic instrumentation -> derive the permitted wrapper names from pinned components/cxx and esp_rom CMake files, reject non-SDK wrappers and diagnostic source paths, and preserve initial false-rejection evidence -> match wrapper provenance against the linked build, not generic name prefixes.

2026-11-15: [Error Handling] BLE cleanup could abandon a failed release or allow an older success to retire ownership while a late subscription release failed -> retain failed device/subscription leases and let only the newest release pass retire them; explicit close/disposal retries cleanup without repeating setup writes -> synchronous-listen and failed-release regressions cover actual acquisition with plugin-boundary stubs.

2026-11-15: [Testing] Flutter analysis scans ignored evidence files ending in .dart -> retain source snapshots with a .dart.txt suffix rather than .dart -> check analyzer inputs before preserving copied source artifacts.
