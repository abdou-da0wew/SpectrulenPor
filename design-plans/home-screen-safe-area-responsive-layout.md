# Home Screen Safe-Area and Responsive Layout

Written against: `5992c4286082d8d926f5210774155168d70271c3`

## Evidence chain

- Surface: `HomeScreen`, the initial `/` route declared by `lib/main.dart`.
- Problem: The user reports that the lower controls can sit beneath Android's Back, Home, and Recents navigation controls. `HomeScreen.build` places its status/source controls, flexible camera area, capture row, optional spectrum card, and analysis footer in one `Scaffold.body` `Column` (`lib/screens/home_screen.dart:53-91`). The traced body has no explicit `SafeArea` or other app-owned bottom-inset boundary. The app targets Android SDK 36 (`android/app/build.gradle.kts:24-46`).
- Design evidence: The user explicitly requires clear space above Android's system navigation controls and responsive layout. The cloned `ceorkm/mobile-app-ui-design` skill (commit `0ad61f0`) specifies mobile-first layout, thumb-zone primary actions, a 4/8-point spacing rhythm, and touch targets of at least 44 logical pixels. Flutter's Android guidance says apps targeting Android 15+ use edge-to-edge by default, and Flutter recommends `SafeArea` to keep content clear of system UI: [edge-to-edge behavior](https://docs.flutter.dev/release/breaking-changes/default-systemuimode-edge-to-edge), [SafeArea and MediaQuery](https://docs.flutter.dev/ui/adaptive-responsive/safearea-mediaquery).
- Owner: `lib/screens/home_screen.dart` owns the Home screen's scaffold and bottom action stack. `lib/widgets/glasses_setup_card.dart` owns the bounded, internally scrollable glasses setup panel.
- Scope and affected surfaces: Home screen only, including the phone-camera and smart-glasses states. Reuse the existing app shell test at `test/widgets/app_shell_test.dart`.
- Uncertainty: The source confirms that the traced body has no explicit safe-area boundary, and the user reports the overlap. No physical-device screenshot or rendered inspection was supplied, so the exact inset values and any device-specific system-bar appearance must be verified on-device. Do not substitute a fixed bottom margin for the live inset.

## Design decision

Give the Home screen one responsive layout owner that consumes operating-system insets exactly once and composes its controls from the available width and height. Keep the camera as the dominant flexible region, but never place a tappable control inside the system navigation area. Preserve the existing muted lavender/mauve brand palette, typography, bilingual EN/AR behavior, and camera-first identity.

## Reuse

- `AppColors` and `buildAppTheme` in `lib/utils/app_theme.dart`.
- `AppTypography` in `lib/utils/app_typography.dart`.
- Existing `_buildCaptureControlBar`, `_buildBottomBar`, `_buildSourceToggle`, and `GlassesSetupCard` compositions.
- Exemplar: `lib/screens/home_screen.dart:53-91` and `lib/widgets/glasses_setup_card.dart:18-52`.

Do not add a second system-inset abstraction if Flutter's `SafeArea` and `MediaQuery` can express the layout. Consume bottom insets once; avoid stacking multiple independent bottom paddings.

## Changes

1. `lib/screens/home_screen.dart`
   - Change: Add an explicit inset boundary to the Home body, with the Scaffold continuing to own the top app bar. Keep the camera preview flexible and apply bottom/side safe-area space to the Home content so the capture controls and analysis footer remain above the OS navigation region. Use the actual system inset from Flutter rather than a hard-coded dp value.
   - Preserve: The existing full-width camera preview, source switching, capture gating, history/chat/settings actions, hazard banner, and smart-glasses telemetry behavior.
   - Verify: With Android three-button navigation and gesture navigation, no Home control or footer is painted underneath the system navigation region.

2. `lib/screens/home_screen.dart`
   - Change: Use `LayoutBuilder` constraints to choose a compact or regular Home composition from the space actually available. Keep the primary camera and Capture & Analyze action available; reduce secondary status/detail density or place secondary details in a bounded scrollable region when height is constrained. Adapt horizontal spacing and action arrangement when width is wider. Do not branch on device model names or add a fixed bottom offset.
   - Preserve: RTL ordering and text direction, long Arabic labels, selected-target state, camera preview sizing, and all existing actions. Use the existing spacing system and ensure touch controls meet the mobile skill's 44-logical-pixel target.
   - Verify: No overflow or clipped action at narrow phone width, short viewport height, landscape, or tablet width.

3. `test/widgets/app_shell_test.dart`
   - Change: Add widget coverage for non-zero bottom `viewPadding`/safe-area insets, narrow and short constraints, landscape constraints, and both locales. Assert that the primary capture controls are laid out above the simulated system navigation inset and remain reachable.
   - Preserve: Existing home, route, and Arabic RTL assertions.
   - Verify: The tests fail if the bottom control stack is moved into the inset or if the responsive composition overflows.

## Scope

- Inherit: Only the Home route and its phone-camera/smart-glasses states.
- Verify: `GlassesSetupCard` and `SpectrumCard` when their optional content is visible, because both change the vertical space available to the camera and bottom controls.
- Exclude: Chat/settings/history redesign, YOLO or camera pipeline behavior, changes to Android navigation mode, and a global fullscreen/immersive-mode change.

## Validation

- Product: Open Home with phone camera, glasses camera, active chat, selected target, hazard banner, and telemetry states. The capture action must remain visible and tappable.
- Interface: Exercise 320-375 logical-pixel widths, a short-height phone viewport, portrait, landscape, and a wider tablet viewport. Verify three-button and gesture navigation on a physical Android device.
- System: Confirm the bottom inset is consumed once, not double-counted, and that keyboard appearance does not create a second oversized gap.
- Repository: `flutter test test/widgets/app_shell_test.dart` → all Home layout and inset assertions pass; `flutter analyze` → no new diagnostics.

## Stop conditions

- Stop if the runtime does not expose the expected navigation inset through Flutter's `MediaQuery`; inspect the Android activity/theme integration before adding a platform-specific workaround.
- Stop if the proposed compact layout would hide or disable the primary capture action.
- Stop if a child already consumes the same inset; reconcile ownership instead of adding another padding layer.

## Design documentation

- After acceptance and validation: Update the Home layout and system-inset rule in `AGENTS.md` or the project's accepted UI guidance. Record that system insets are dynamic and must not be replaced with fixed navigation-bar margins.
