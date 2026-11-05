import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_glass_app/main.dart';

Future<SharedPreferences> mockPrefs([
  Map<String, Object> initial = const {},
]) async {
  SharedPreferences.setMockInitialValues(initial);
  return SharedPreferences.getInstance();
}

Future<void> pumpApp(
  WidgetTester tester,
  SharedPreferences prefs, {
  Map<String, String> secrets = const {},
}) async {
  // appLocale is a global ValueNotifier — reset between tests.
  appLocale.value = const Locale('en');
  await tester.pumpWidget(SpectruLenPorApp(prefs: prefs, secrets: secrets));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('home screen renders brand, source switch, permission & analysis bar (EN)',
      (tester) async {
    final prefs = await mockPrefs();
    await pumpApp(tester, prefs);

    // Brand title in the AppBar
    expect(find.text('SpectruLenPor'), findsOneWidget);
    // Camera source toggle buttons
    expect(find.text('Phone camera'), findsWidgets);
    expect(find.text('Glasses'), findsOneWidget);
    // Permission card (camera denied in test VM)
    expect(find.text('Camera Access Required'), findsOneWidget);
    expect(find.text('Grant Access'), findsOneWidget);
    // Bottom Live Analysis bar
    expect(find.text('AI analysis'), findsOneWidget);
    expect(find.text('Waiting for analysis…'), findsOneWidget);

    // Switching to Smart Glasses shows the BLE ConnectionStatusBar
    await tester.tap(find.text('Glasses'));
    await tester.pumpAndSettle();
    expect(find.text('Connect glasses'), findsOneWidget);
  });

  testWidgets('app reacts to locale flip — Arabic renders RTL',
      (tester) async {
    final prefs = await mockPrefs();
    await pumpApp(tester, prefs);

    appLocale.value = const Locale('ar');
    await tester.pumpAndSettle(const Duration(milliseconds: 900));

    final ctx = tester.element(find.byType(Scaffold).first);
    expect(Localizations.localeOf(ctx).languageCode, 'ar');
    expect(Directionality.of(ctx), TextDirection.rtl);
    expect(find.text('سبكترو لِن بور'), findsOneWidget);
    expect(find.textContaining('تحليل الذكاء الاصطناعي'), findsOneWidget);
    expect(find.text('يلزم إذن الكاميرا'), findsOneWidget);
  });

  testWidgets('settings route shows key fields, chain, diagnostics, credits & version card',
      (tester) async {
    final prefs = await mockPrefs();
    await pumpApp(
      tester,
      prefs,
      secrets: const {
        'moondream': 'md-secret',
        'openrouter_llm': 'llm-secret',
        'openrouter_tts': 'tts-secret',
      },
    );

    // Tall viewport: the settings screen is a lazy ListView — a phone-sized
    // test surface leaves the API-key cards unbuilt (unfindable). A tall
    // surface builds the whole column at once.
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));

    expect(find.text('MOONDREAM3 CLOUD — PRIMARY VISION'), findsOneWidget);
    expect(find.text('OPENROUTER API'), findsOneWidget);

    // Seeded keys are preserved as the real values (not placeholder strings).
    // Tall viewport builds the lazy ListView's API-key cards up front.
    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields.length, greaterThanOrEqualTo(3));
    expect(
      fields.map((f) => f.controller?.text),
      containsAllInOrder(<String>['md-secret', 'llm-secret', 'tts-secret']),
    );

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
    expect(find.textContaining('DIAGNOSTICS'), findsWidgets);

    // Scroll down to About + Build & Version card.
    await tester.scrollUntilVisible(
      find.textContaining('Malak Adel Sayed Hassan'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('fish-audio/s2.1-pro-free:free'),
      findsWidgets,
    );
    expect(find.textContaining('Malak Adel Sayed Hassan'), findsOneWidget);

    // '(build ' is unique to the version card (the about text also contains
    // 'SpectruLenPor v…', which would break the finder's single-match rule).
    await tester.scrollUntilVisible(
      find.textContaining('(build '),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('(build '), findsOneWidget);
  });
}
