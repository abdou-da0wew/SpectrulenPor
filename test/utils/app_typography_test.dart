import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/utils/app_typography.dart';

void main() {
  const en = Locale('en');
  const ar = Locale('ar');

  test('isArabic detection', () {
    expect(AppTypography.isArabic(en), isFalse);
    expect(AppTypography.isArabic(ar), isTrue);
    expect(AppTypography.isArabic(const Locale('ar', 'EG')), isTrue);
  });

  test('EN display style uses Jaro (the stylish font)', () {
    final s = AppTypography.display(en, fontSize: 30);
    expect(s.fontFamily, startsWith('Jaro'));
  });

  test('EN body style uses Rubik (normal text)', () {
    final s = AppTypography.body(en, fontSize: 14);
    expect(s.fontFamily, startsWith('Rubik'));
  });

  test('EN paragraph style uses Space Mono (long text)', () {
    final s = AppTypography.paragraph(en, fontSize: 13.5);
    expect(s.fontFamily, startsWith('SpaceMono'));
  });

  test('ALL Arabic styles use Zain', () {
    expect(AppTypography.display(ar).fontFamily, startsWith('Zain'));
    expect(AppTypography.body(ar).fontFamily, startsWith('Zain'));
    expect(AppTypography.paragraph(ar).fontFamily, startsWith('Zain'));
  });

  test('theme text theme: EN = Rubik base + Jaro display/headline', () {
    final theme = AppTypography.textThemeFor(en, ThemeData.fallback().textTheme);
    expect(theme.bodyMedium?.fontFamily, startsWith('Rubik'));
    expect(theme.displayLarge?.fontFamily, startsWith('Jaro'));
    expect(theme.headlineSmall?.fontFamily, startsWith('Jaro'));
    expect(theme.titleLarge?.fontFamily, startsWith('Jaro'));
    // titleMedium stays Rubik (normal text tier)
    expect(theme.titleMedium?.fontFamily, startsWith('Rubik'));
  });

  test('theme text theme: AR = Zain everywhere', () {
    final theme = AppTypography.textThemeFor(ar, ThemeData.fallback().textTheme);
    expect(theme.bodyMedium?.fontFamily, startsWith('Zain'));
    expect(theme.displayLarge?.fontFamily, startsWith('Zain'));
    expect(theme.headlineSmall?.fontFamily, startsWith('Zain'));
  });

  testWidgets('context helpers resolve the ambient locale', (tester) async {
    late TextStyle display, body, paragraph;
    await tester.pumpWidget(
      Localizations(
        locale: ar,
        delegates: const [
          DefaultWidgetsLocalizations.delegate,
          DefaultMaterialLocalizations.delegate,
        ],
        child: Builder(
          builder: (context) {
            display = AppTypography.displayOf(context);
            body = AppTypography.bodyOf(context);
            paragraph = AppTypography.paragraphOf(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(display.fontFamily, startsWith('Zain'));
    expect(body.fontFamily, startsWith('Zain'));
    expect(paragraph.fontFamily, startsWith('Zain'));
  });
}
