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
    expect(find.text('Phone Camera'), findsWidgets);
    expect(find.text('Smart Glasses'), findsOneWidget);
    // Permission card (camera denied in test VM)
    expect(find.text('Camera Access Required'), findsOneWidget);
    expect(find.text('Grant Access'), findsOneWidget);
    // Bottom Live Analysis bar
    expect(find.text('Live Analysis'), findsOneWidget);
    expect(find.text('Waiting for analysis…'), findsOneWidget);

    // Switching to Smart Glasses shows the BLE ConnectionStatusBar
    await tester.tap(find.text('Smart Glasses'));
    await tester.pumpAndSettle();
    expect(find.text('Connect Glasses'), findsOneWidget);
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
    expect(find.textContaining('التحليل الفوري'), findsOneWidget);
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

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));

    expect(find.textContaining('MOONDREAM3'), findsOneWidget);
    expect(find.textContaining('OPENROUTER'), findsOneWidget);

    // Seeded TTS key is preserved as the real key (not a placeholder string).
    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields, hasLength(3));
    expect(fields[0].controller?.text, 'md-secret');
    expect(fields[1].controller?.text, 'llm-secret');
    expect(fields[2].controller?.text, 'tts-secret');

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

    await tester.scrollUntilVisible(
      find.textContaining('SpectruLenPor v'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('SpectruLenPor v'), findsOneWidget);
  });
}
