import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// SpectruLenPor typography system (user-specified font mapping):
///
///   * **Jaro** ......... the stylish font — brand, headings, display, big
///                        numbers (EN text)
///   * **Rubik** ........ all other normal text (EN)
///   * **Space Mono** ... long text paragraphs (EN) — AI analysis bodies,
///                        about text, diagnostics
///   * **Zain** ......... ALL Arabic text (display, body and paragraphs —
///                        it covers Arabic script; Space Mono / Jaro / Rubik
///                        have no Arabic glyphs)
///
/// All four families are bundled under `assets/fonts/` and declared in
/// pubspec under `google_fonts:`, so no runtime font fetching is required
/// (works fully offline, screenshots are deterministic).
class AppTypography {
  AppTypography._();

  static bool isArabic(Locale locale) =>
      locale.languageCode.toLowerCase().startsWith('ar');

  // ---------------------------------------------------------------------------
  // ROLE STYLES — use these from widgets
  // ---------------------------------------------------------------------------

  /// Stylish display style — Jaro (EN) / Zain ExtraBold (AR).
  static TextStyle display(
    Locale locale, {
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? height,
    double? letterSpacing,
  }) {
    final size = fontSize ?? 20;
    if (isArabic(locale)) {
      return GoogleFonts.zain(
        fontSize: size,
        fontWeight: fontWeight ?? FontWeight.w800,
        color: color,
        height: height,
      );
    }
    return GoogleFonts.jaro(
      fontSize: size,
      fontWeight: fontWeight ?? FontWeight.w400,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  /// Normal text style — Rubik (EN) / Zain (AR).
  static TextStyle body(
    Locale locale, {
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? height,
  }) {
    final size = fontSize ?? 14;
    if (isArabic(locale)) {
      return GoogleFonts.zain(
        fontSize: size,
        fontWeight: fontWeight ?? FontWeight.w400,
        color: color,
        height: height,
      );
    }
    return GoogleFonts.rubik(
      fontSize: size,
      fontWeight: fontWeight ?? FontWeight.w400,
      color: color,
      height: height,
    );
  }

  /// Long-paragraph style — Space Mono (EN) / Zain (AR).
  static TextStyle paragraph(
    Locale locale, {
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? height,
  }) {
    final size = fontSize ?? 13.5;
    if (isArabic(locale)) {
      return GoogleFonts.zain(
        fontSize: size,
        fontWeight: fontWeight ?? FontWeight.w400,
        color: color,
        height: height ?? 1.55,
      );
    }
    return GoogleFonts.spaceMono(
      fontSize: size,
      fontWeight: fontWeight ?? FontWeight.w400,
      color: color,
      height: height ?? 1.55,
    );
  }

  /// Convenience builders that resolve the locale from [context].
  static TextStyle displayOf(BuildContext context,
          {double? fontSize, FontWeight? fontWeight, Color? color}) =>
      display(Localizations.localeOf(context),
          fontSize: fontSize, fontWeight: fontWeight, color: color);

  static TextStyle bodyOf(BuildContext context,
          {double? fontSize, FontWeight? fontWeight, Color? color}) =>
      body(Localizations.localeOf(context),
          fontSize: fontSize, fontWeight: fontWeight, color: color);

  static TextStyle paragraphOf(BuildContext context,
          {double? fontSize, Color? color}) =>
      paragraph(Localizations.localeOf(context),
          fontSize: fontSize, color: color);

  // ---------------------------------------------------------------------------
  // THEME INTEGRATION
  // ---------------------------------------------------------------------------

  /// Full Material [TextTheme] for a locale:
  ///   * EN — Rubik base + Jaro on display/headline/title styles.
  ///   * AR — Zain everywhere.
  static TextTheme textThemeFor(Locale locale, TextTheme fallback) {
    if (isArabic(locale)) {
      return GoogleFonts.zainTextTheme(fallback);
    }
    final rubik = GoogleFonts.rubikTextTheme(fallback);
    final jaro = GoogleFonts.jaroTextTheme(fallback);
    // Jaro (stylish) owns the display & headline tiers; Rubik owns the rest.
    return rubik.copyWith(
      displayLarge: jaro.displayLarge,
      displayMedium: jaro.displayMedium,
      displaySmall: jaro.displaySmall,
      headlineLarge: jaro.headlineLarge,
      headlineMedium: jaro.headlineMedium,
      headlineSmall: jaro.headlineSmall,
      titleLarge: jaro.titleLarge,
    );
  }
}
