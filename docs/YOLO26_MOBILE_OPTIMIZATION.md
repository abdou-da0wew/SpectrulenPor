# Vision pipeline performance and reliability

This document describes the current implementation. Performance numbers below
are scheduling limits, not measured FPS claims. Real throughput and thermal
behaviour still require the Android phone and ESP32 camera to be connected.

## Android YOLO26-Nano

### Execution provider selection

`YoloInferenceChannel.kt` opens one ONNX Runtime session at a time, in this
order:

1. NNAPI with FP16 enabled.
2. XNNPACK if NNAPI cannot execute the model.
3. CPU as the final fallback.

Each candidate is warmed once, then closed before trying the next candidate.
The selected session uses at most two intra-op threads and one inter-op thread.
This avoids constructing three sessions and running repeated warmups during app
startup. `epWarmupMs` is the one-run provider warmup time, not a benchmark.

### Runtime resource governor

- A single-thread executor owns model inference and preprocessing buffers.
- Detection calls are single-flight. A second request receives a recent stable
  result instead of entering an unbounded executor queue.
- CPU fallback has a 450 ms minimum inference interval; NNAPI/XNNPACK start at
  250 ms. Moderate thermal state raises the interval to at least 850 ms.
- Battery below 10% raises the interval to at least 1 second.
- Severe thermal state or low system memory skips inference and clears boxes.
- Large source JPEGs are sampled before bitmap allocation; pixel and tensor
  scratch arrays are reused between inferences.
- No inference runs when the live camera pipeline is inactive.

The Flutter side serializes the low-cost vision gate and YOLO stage. It drops
frames while analysis is busy rather than building a backlog. The preview stream
is independent and continues to receive frames. Detection is user-configurable
from 1 to 4 FPS, with 2 FPS as the default.

### Detection correctness

The bundled `yolo26n.onnx` is an end-to-end YOLO26-Nano model. Its `[1, 300, 6]`
output is already NMS-free, so the app no longer applies a second NMS pass that
could suppress distinct adjacent objects. Classic model heads still use
class-aware NMS. Input dimensions come from the ONNX graph.

**Accuracy limitation:** the bundled model uses COCO classes. It can tag common
objects such as bottles, cups, books and people, but it is not a chemistry or
laboratory-specific detector. Better chemical-container, instrument, label or
hazard-symbol recall requires a validated custom dataset and a separately
exported model. Threshold changes cannot teach new classes.

## Moondream cloud analysis

Selected-object analysis now:

1. Crops the selected YOLO box with a 15% context margin in an isolate.
2. Sends one structured VQA request for object, state, visible text and hazards.
3. Runs a reasoning-enabled retry only when the first object identification is
   missing or explicitly uncertain.
4. Runs a separate hazard-pictogram verification on the same crop.

The marked full frame is not uploaded. If cropping fails or no box is selected,
analysis fails closed rather than substituting the complete frame. Large crops
are capped at 1280 px and JPEG quality 92. Moondream request admission is
serialized to preserve the base 2-request/second limit.

The llama.cpp Moondream bridge is currently only a scaffold: it is not wired
into the Android Gradle build and there is no packaged GGUF/mmproj model. The
local cascade must not be described as offline Moondream until both the native
library and model assets are shipped and tested.

## ESP32-CAM and UDP transport

### Capture profiles

With PSRAM, the firmware selects by Wi-Fi RSSI:

| Profile | Resolution | Packet pacing | Additional frame interval |
|---|---:|---:|---:|
| Strong | XGA 1024×768 | 1 ms yield per 8 packets | 0 ms |
| Medium | SVGA 800×600 | 1 ms yield per 8 packets | 5 ms |
| Weak | VGA 640×480 | 1 ms per packet | 10 ms |
| Fallback | QVGA 320×240 | 2 ms per packet | 25 ms |

Without PSRAM, the camera remains on the QVGA-safe profile. UDP data packets
remain MTU-safe at 960 JPEG bytes with the existing XOR parity scheme. The
frame-send deadline is 3 seconds; transient socket pressure still uses bounded
retries. These are target settings, not a guarantee of 20–30 FPS at XGA: sensor
capture time, JPEG size, Wi-Fi airtime and Android decode time must be measured
on the actual hardware.

### Discovery and recovery

The phone can leave the ESP32 IP field empty. It broadcasts the existing UDP
peer-keepalive command on port 8888 and accepts the camera's one-byte echo or
`$CMD:keepalive` response to learn the ESP32's current address. This uses the
existing protocol; no new packet format is introduced. A stalled stream triggers
peer rediscovery so a changed DHCP address can be recovered without restarting
the app. Both devices must be on the same Wi-Fi LAN and client isolation must
not block broadcast traffic.

BLE remains commissioning-only. Video and runtime commands stay on UDP.

## Validation status

- Android/Dart static analysis: clean for the modified Dart files.
- BLE acquisition lifecycle tests: 43 passing.
- UDP transport tests: 20 passing, including automatic discovery and socket recovery.
- Moondream service tests: 13 passing, including crop-only upload behaviour.
- ESP-IDF firmware build: successful; app image fits the configured partition.
- Firmware host suite: 206 passing; transport testbench: 128 passing.
- Hardware throughput, thermal throttling, broadcast discovery across the user's
  router, and camera reconnect behaviour still need a connected phone + ESP32
  end-to-end run. Do not mark 20–30 FPS as verified before that run.
