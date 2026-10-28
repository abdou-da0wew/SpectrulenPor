import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_glass_app/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SpectruLenPorApp boots HomeScreen cleanly', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    appLocale.value = const Locale('en');

    await tester.pumpWidget(SpectruLenPorApp(prefs: prefs, secrets: const {}));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('SpectruLenPor'), findsOneWidget);
    expect(find.text('Phone Camera'), findsWidgets);
    expect(find.text('Smart Glasses'), findsOneWidget);
  });
}
