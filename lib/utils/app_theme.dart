import 'package:flutter/material.dart';

/// SpectrulenPor brand palette (user-supplied).
///
/// CSS HEX source:
///   alabaster-grey   #E5E3E1
///   dust-grey        #D4D3CD
///   silver           #C2BEC0
///   dusty-mauve      #A67E98
///   dusty-lavender   #825376
///
/// Usage map:
///   * background        -> alabasterGrey (large surfaces)
///   * surface / cards   -> surface (white-ish) + dustGrey for alt cards
///   * outline / divider -> silver
///   * primary actions   -> dustyLavender (deep, high contrast w/ white text)
///   * accents / chips   -> dustyMauve
///   * text              -> inkDark on light; alabasterGrey on primary
class AppColors {
  AppColors._();

  // Core brand palette
  static const Color alabasterGrey = Color(0xFFE5E3E1);
  static const Color dustGrey = Color(0xFFD4D3CD);
  static const Color silver = Color(0xFFC2BEC0);
  static const Color dustyMauve = Color(0xFFA67E98);
  static const Color dustyLavender = Color(0xFF825376);

  // Derived tones for readable text on light backgrounds
  static const Color inkDark = Color(0xFF3A2434); // deep plum ink
  static const Color inkSoft = Color(0xFF6B5566); // muted plum-grey text
  static const Color surfaceLight = Color(0xFFFBFAF9); // card surface
  static const Color success = Color(0xFF5F8D6B); // desaturated green
  static const Color warning = Color(0xFFC98A2D); // amber
  static const Color danger = Color(0xFFB04A4A); // desaturated red

  // Brand gradients (from user's SCSS gradient spec)
  static const LinearGradient gradientRight = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [alabasterGrey, dustGrey, silver, dustyMauve, dustyLavender],
  );

  static const LinearGradient gradientTop = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [dustyLavender, dustyMauve, silver, dustGrey, alabasterGrey],
  );

  /// Subtle brand gradient for headers / hero areas.
  static const LinearGradient headerGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [dustyLavender, dustyMauve],
  );
}

/// Builds the Material 3 light theme for SpectrulenPor.
ThemeData buildAppTheme() {
  const seed = AppColors.dustyLavender;

  final colorScheme = ColorScheme.light(
    primary: seed,
    onPrimary: Colors.white,
    primaryContainer: AppColors.dustyMauve,
    onPrimaryContainer: Colors.white,

    secondary: AppColors.dustyMauve,
    onSecondary: Colors.white,
    secondaryContainer: AppColors.alabasterGrey,
    onSecondaryContainer: AppColors.inkDark,

    tertiary: AppColors.silver,
    onTertiary: AppColors.inkDark,

    surface: AppColors.surfaceLight,
    onSurface: AppColors.inkDark,
    surfaceContainerHighest: AppColors.dustGrey,
    onSurfaceVariant: AppColors.inkSoft,

    error: AppColors.danger,
    onError: Colors.white,

    outline: AppColors.silver,
    outlineVariant: AppColors.dustGrey,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AppColors.alabasterGrey,
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.inkDark,
      displayColor: AppColors.inkDark,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.dustyLavender,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: Colors.white,
        letterSpacing: 0.3,
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surfaceLight,
      elevation: 2,
      shadowColor: AppColors.silver.withOpacity(0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppColors.silver.withOpacity(0.6)),
      ),
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.dustyLavender,
        foregroundColor: Colors.white,
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.dustyLavender,
        side: const BorderSide(color: AppColors.dustyLavender, width: 1.4),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceLight,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.silver),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.silver),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.dustyLavender, width: 1.6),
      ),
      labelStyle: const TextStyle(color: AppColors.inkSoft),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return Colors.white;
        return AppColors.silver;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return AppColors.dustyMauve;
        }
        return AppColors.dustGrey;
      }),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: AppColors.dustyMauve,
      inactiveTrackColor: AppColors.dustGrey,
      thumbColor: AppColors.dustyLavender,
      overlayColor: Color(0x33A67E98),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.dustyMauve,
      linearTrackColor: AppColors.dustGrey,
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.dustGrey,
      thickness: 1,
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: AppColors.dustGrey,
      selectedColor: AppColors.dustyMauve,
      labelStyle: const TextStyle(color: AppColors.inkDark),
      secondaryLabelStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.inkDark,
      contentTextStyle: const TextStyle(color: AppColors.alabasterGrey),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}
