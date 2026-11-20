import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/widgets/home_layout.dart';

void main() {
  testWidgets('compact layout keeps optional glasses spectrum available',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: HomeLayout(
            statusBar: SizedBox(height: 32),
            sourceToggle: SizedBox(height: 44),
            glassesSetup: SizedBox(height: 48),
            camera: ColoredBox(color: Colors.black),
            captureAction: SizedBox(height: 48),
            spectrum: Text('Spectrum telemetry'),
            analysisFooter: SizedBox(height: 48),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('home-compact-layout')), findsOneWidget);
    expect(find.text('Spectrum telemetry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
