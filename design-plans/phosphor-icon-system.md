# Adopt a Consistent Phosphor Icon System

Written against: `5992c4286082d8d926f5210774155168d70271c3`

## Evidence chain

- Surface: The Flutter app's in-app UI, beginning with the primary `HomeScreen` and continuing through chat, settings, history, diagnostics, and shared widgets.
- Problem: The current project rule explicitly says in-app iconography uses Material Icons (`AGENTS.md:12`), and Dart UI code contains 143 distinct `Icons.*` glyph references. The user has now explicitly selected Phosphor as the app-wide icon family, so the current rule and current call sites conflict with the requested direction.
- Design evidence: The cloned `ceorkm/mobile-app-ui-design` skill calls for a consistent icon style across the application and visual hierarchy without random style changes. The local brand owner remains `lib/utils/app_theme.dart` and its existing Material 3 lavender/mauve palette. The selected Phosphor package documents 1,500+ glyphs, six visual styles, plain `IconData` constants compatible with Dart 3.x, and a dedicated widget for Duotone: [package documentation](https://pub.dev/packages/phosphoricons_flutter).
- Owner: Existing icon call sites in `lib/screens/` and `lib/widgets/`; project-wide icon policy in `AGENTS.md`.
- Scope and affected surfaces: All user-facing Flutter UI icon call sites under `lib/`. Documentation SVGs under `docs/assets/icons/` are a separate existing documentation asset set and are not runtime Flutter widgets.
- Uncertainty: The package is community-maintained and explicitly not affiliated with the original Phosphor Icons creators. Confirm the dependency's current release, license, and lockfile resolution during implementation; do not silently substitute a different package.

## Design decision

Use the Phosphor icon family consistently throughout the Flutter UI while preserving the existing app palette, typography, interaction behavior, and semantic labels. Standardize on Regular icons for ordinary actions and Fill only for intentionally active/selected states. Do not mix Material and Phosphor icon families in the same user-facing app surface after migration, except where a native platform-provided asset is required.

## Reuse

- Existing Material 3 theme and brand colors in `lib/utils/app_theme.dart`.
- Existing `Icon`, `IconButton`, `IconButton.filledTonal`, and other Material controls; Phosphor's flat glyphs can be passed as ordinary `IconData`.
- Dependency/API selected for implementation: `phosphoricons_flutter: ^1.1.1`, imported from `package:phosphoricons_flutter/phosphoricons_flutter.dart`. Use `PhosphorIconsRegular.<name>` by default and `PhosphorIconsFill.<name>` for active states. Use `PhosphorIcon` only for Duotone glyphs.
- Exemplar: `lib/screens/home_screen.dart:97-180` for app-bar actions and `lib/utils/app_theme.dart:62-139` for the existing theme owner.

## Changes

1. `pubspec.yaml` and `pubspec.lock`
   - Change: Add the selected Phosphor package and resolve it through the project's normal Flutter dependency workflow. Confirm the resolved package supports the project's declared Dart SDK range before accepting the lockfile.
   - Preserve: Existing Flutter SDK constraints unless package metadata proves a minimum-version increase is required. Do not install a different icon library as a fallback without recording the compatibility reason.
   - Verify: Dependency resolution succeeds on the project's actual Flutter/Dart toolchain and the package license is recorded in dependency metadata.

2. `lib/screens/` and `lib/widgets/`
   - Change: Replace all in-app Material `Icons.*` glyph references with explicit Phosphor equivalents. Use Regular for ordinary controls and Fill for active/selected state only; keep size, color, tooltip, semantic label, tap target, and action behavior unchanged unless the existing control already has an approved UI change.
   - Preserve: Every existing icon's meaning, state distinction, color role, tooltip/localized label, RTL behavior, and interaction. Do not replace icon-only controls with unlabeled glyphs.
   - Verify: Search all `lib/` Dart files for remaining `Icons.*` call sites; any remaining match must be documented as a deliberate platform-specific exception.

3. `AGENTS.md`
   - Change: Replace the in-app Material Icons rule with the accepted Phosphor family/style policy. Keep the separate rule for committed Phosphor SVGs used in documentation, and retain the no-emoji requirement.
   - Preserve: Existing bilingual and accessibility requirements.
   - Verify: Future contributors and agents receive one unambiguous runtime iconography rule.

4. `test/widgets/app_shell_test.dart` and relevant widget tests
   - Change: Keep existing icon-driven actions covered by stable tooltips/keys and add assertions for the migrated icon states where useful.
   - Preserve: Existing navigation, settings, camera source, and locale assertions.
   - Verify: Icon migration does not change control semantics, hit areas, state, or navigation behavior.

## Scope

- Inherit: All Flutter UI screens and shared widgets under `lib/screens/` and `lib/widgets/`.
- Verify: Every interactive icon-only control and active/inactive icon pair, including Home app-bar controls, chat actions, settings sections, history, and diagnostics.
- Exclude: Android launcher/adaptive icons, third-party plugin-owned icons, documentation SVG assets, typography, app colors, and non-UI image assets.

## Validation

- Product: Exercise every icon-only action and active/inactive state. The icon must still communicate the same action/state and expose the same tooltip or semantic label.
- Interface: Check both light brand surfaces and dark camera overlays, portrait/landscape, and English/Arabic RTL.
- System: Confirm consistent Regular/Fill usage, no accidental mixture of icon families, no missing glyphs, and no Duotone glyph passed to Flutter's standard `Icon` widget.
- Repository: `flutter pub get` → dependency resolves; `flutter analyze` → no new diagnostics; `flutter test` → all existing tests pass; `grep -R 'Icons\\.' lib --include='*.dart'` → no undocumented Material glyphs remain.

## Stop conditions

- Stop if the selected package is incompatible with the actual Flutter/Dart SDK or its license/release provenance changes.
- Stop if a Material glyph has no reliable Phosphor equivalent; identify the exact missing semantic icon before choosing an alternative.
- Stop if the migration would alter an action's meaning, state announcement, or existing localized tooltip.

## Design documentation

- After acceptance and validation: Update `AGENTS.md` to make Phosphor the runtime Flutter icon system, document the Regular/Fill usage rule, and clarify that documentation SVG assets remain separate. Do not change the color or typography decisions.
