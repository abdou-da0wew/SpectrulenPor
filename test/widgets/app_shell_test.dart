import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_glass_app/main.dart';

Future<SharedPreferences> mockPrefs() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  return SharedPreferences.getInstance();
}

Future<void> pumpApp(WidgetTester tester, SharedPreferences prefs) async {
  // The appLocale is a global ValueNotifier — reset between tests.
  appLocale.value = const Locale('en');
  await tester.pumpWidget(SpectruLenPorApp(prefs: prefs, secrets: const {}));
  await tester.pump(const Duration(milliseconds: 400)); // post-frame camera kick
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('home screen renders brand, source switch and core cards (EN)',
      (tester) async {
    final prefs = await mockPrefs();
    await pumpApp(tester, prefs);

    // Brand title in the AppBar
    expect(find.text('SpectruLenPor'), findsOneWidget);
    // Camera source segmented buttons (generic type → predicate finder)
    expect(
        find.byWidgetPredicate((w) => w is SegmentedButton), findsOneWidget);

    // Below-the-fold lazy items — scroll the action row into view.
    await tester.scrollUntilVisible(
      find.textContaining('Analyze now'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Analyze now'), findsWidgets); // button + hint

    // Keep scrolling to the credits footer.
    await tester.scrollUntilVisible(
      find.textContaining('Malak Adel Sayed Hassan'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Malak Adel Sayed Hassan'), findsOneWidget);
    expect(find.textContaining('AI analysis'), findsOneWidget);
  });

  testWidgets('app reacts to locale flip — Arabic renders RTL',
      (tester) async {
    final prefs = await mockPrefs();
    await pumpApp(tester, prefs);

    appLocale.value = const Locale('ar');
    await tester.pumpAndSettle(const Duration(milliseconds: 600));

    final ctx = tester.element(find.byType(Scaffold).first);
    expect(Localizations.localeOf(ctx).languageCode, 'ar');
    expect(Directionality.of(ctx), TextDirection.rtl);
    expect(find.textContaining('تحليل'), findsWidgets);
    // Arabic flash text is Zain-family (font test asserts the mapping).
  });

  testWidgets('settings route shows key fields, chain and diagnostics',
      (tester) async {
    final prefs = await mockPrefs();
    await pumpApp(tester, prefs);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));

    // Settings sections (section headers are rendered uppercase). The
    // chain radios + diagnostics are below the fold — scroll stepwise.
    expect(find.textContaining('MOONDREAM3'), findsOneWidget);
    expect(find.textContaining('OPENROUTER'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.textContaining('gemma-4-26b-a4b-it:free'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('gemma-4-26b-a4b-it:free'), findsOneWidget);
    expect(find.textContaining('inkling-small:free'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.textContaining('nemotron-3-nano'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('nemotron-3-nano'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.textContaining('DIAGNOSTICS'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('DIAGNOSTICS'), findsOneWidget);

    // About (with credits) sits at the very bottom of the lazy list.
    await tester.scrollUntilVisible(
      find.textContaining('Malak Adel Sayed Hassan'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(
        find.textContaining('fish-audio/s2.1-pro-free:free'), findsWidgets);
    expect(find.textContaining('Malak Adel Sayed Hassan'), findsOneWidget);
  });
}
