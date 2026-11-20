# Home Screen Rendering Smoothness

Written against: `5992c4286082d8d926f5210774155168d70271c3`

## Evidence chain

- Surface: `HomeScreen`, route `/`, while either the phone camera or ESP32 glasses stream is active.
- Problem: `HomeScreen.build` subscribes to the complete `RecognitionState` with `context.watch<RecognitionState>()` (`lib/screens/home_screen.dart:53-56`). The frame subscription calls `_onFrame` for each streaming frame (`lib/models/recognition_state.dart:811-815,854-858`), and `_onFrame` calls `notifyListeners()` before checking the separate inference throttle (`lib/models/recognition_state.dart:937-961`). Consequently the full Home widget subtree is invalidated for every incoming frame, even when the vision pipeline skips that frame.
- Design evidence: The user explicitly asks for smoother UI and responsiveness while live camera processing continues. The cloned mobile UI skill asks for smooth, purposeful transitions and avoidance of heavy visual effects. The pasted interaction-design guidance assigns 100-150 ms to micro-feedback and 200-300 ms to small state transitions, and recommends animating opacity/transform rather than layout dimensions. The pasted accessible-animation guidance requires tiered reduced-motion behavior rather than removing every useful transition.
- Owner: `RecognitionState._onFrame` owns frame notifications; `HomeScreen` owns the broad subscription that currently reacts to them.
- Scope and affected surfaces: Home screen live camera presentation and its directly connected frame/detection overlay. No other app route should receive high-frequency frame-driven rebuilds as a side effect.
- Uncertainty: Source proves the notification/rebuild path, but no profile trace or frame-time benchmark was collected in this read-only audit. Actual frame pacing and device-specific jank must be measured before and after implementation.

## Design decision

Separate high-frequency camera presentation updates from lower-frequency app-wide UI state. A new camera frame should refresh only the camera/overlay consumer that needs it; it should not rebuild the app bar, source controls, capture row, telemetry summary, and every other Home child. Keep inference throttling and frame freshness independent from UI notification frequency.

## Reuse

- Existing frame streams and state owner in `lib/models/recognition_state.dart`.
- Existing provider dependency and Home composition in `lib/screens/home_screen.dart`.
- Existing camera and detection overlay widgets imported by HomeScreen.
- Exemplar: `lib/models/recognition_state.dart:811-858,937-961` and `lib/screens/home_screen.dart:53-91`.

Use the project's existing Provider/Flutter state-management conventions. Do not add an animation package or a second global state-management framework.

## Changes

1. `lib/models/recognition_state.dart`
   - Change: Move frame-only presentation changes to a dedicated, narrowly scoped notifier/value channel consumed by the camera preview and detection overlay. Keep `notifyListeners()` on the app-wide `RecognitionState` for meaningful lower-frequency state changes such as connection, selection, capture, hazard, and analysis status. Do not publish an app-wide notification for every raw camera frame.
   - Preserve: Every fresh frame remains available to the vision pipeline; the existing one-in-flight guard and FPS throttle remain authoritative; detections, selected-box state, and explicit user-gated capture retain their current behavior.
   - Verify: A frame arriving while inference is throttled updates the camera presentation as needed without invalidating unrelated Home controls.

2. `lib/screens/home_screen.dart` and the existing camera/overlay widget owner
   - Change: Remove the broad frame-sensitive subscription from the Home root. Subscribe only the camera/overlay subtree to the dedicated frame notifier; use narrow `Selector`/consumer boundaries for the independent controls and status values. Keep widget identity stable so the native camera preview is not recreated on ordinary state changes.
   - Preserve: All controls update immediately for their own state changes, camera source switches still transition correctly, and live bounding boxes remain synchronized with their frames.
   - Verify: A frame burst does not cause the app bar, source toggle, capture button, or analysis footer to rebuild for every raw frame.

3. Home screen transition owners
   - Change: Keep transitions purposeful and cheap: prefer short opacity/color feedback and small transform-based movement; do not animate width/height or introduce large blur/backdrop-filter layers. Respect the platform reduced-animation preference: remove large-area movement/scale, soften small transitions to a brief fade, and keep essential progress/focus feedback.
   - Preserve: Existing 180-280 ms state transitions where they already communicate a meaningful camera/source change; do not add continuous decorative animation.
   - Verify: Transitions remain interruptible, controls never wait for an animation to finish, and reduced-motion mode has no large-area slide/zoom.

## Scope

- Inherit: The live Home camera preview and detection overlay only.
- Verify: The app bar, status/source controls, capture action, optional SpectrumCard, and bottom analysis summary no longer depend on raw-frame notifications.
- Exclude: Changes to YOLO model architecture, inference providers, camera capture rate, UDP/BLE transport, or Moondream processing. Those are separate performance owners and must not be changed as part of this UI plan.

## Validation

- Product: Stream frames while switching camera source, selecting/deselecting boxes, receiving telemetry, showing a hazard, and opening Capture & Analyze. Live boxes must remain correct and no control may become stale.
- Interface: Verify normal and reduced-motion settings, rapid source changes, loading/error states, and both EN/AR layouts.
- System: Use Flutter DevTools in profile mode on the connected Android device to compare frame timings and widget rebuild counts before/after. The app's global Home controls should not rebuild at the raw camera stream cadence. Confirm that no frame queue or additional inference work is introduced.
- Repository: `flutter test test/widgets/app_shell_test.dart` and relevant recognition-state/camera widget tests → pass; `flutter analyze` → no new diagnostics; profile trace → fewer unrelated Home subtree rebuilds during a sustained stream.

## Stop conditions

- Stop if isolating frame notifications would delay or reorder the detection overlay relative to its corresponding frame.
- Stop if the native camera preview is recreated, the frame queue grows, or capture privacy gating changes.
- Stop if reduced-motion state cannot be read through the project's supported Flutter SDK API; inspect the SDK version before selecting the API.

## Design documentation

- After acceptance and validation: Record the frame-vs-app-state notification ownership and the reduced-motion policy in the accepted architecture/UI guidance. Do not document an FPS or frame-time improvement until it has been measured.
