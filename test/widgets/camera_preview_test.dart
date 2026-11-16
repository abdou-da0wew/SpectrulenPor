import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/l10n/app_localizations.dart';
import 'package:smart_glass_app/models/bluetooth_status.dart';
import 'package:smart_glass_app/widgets/camera_preview.dart';

void main() {
  for (final locale in AppLocalizations.supportedLocales) {
    for (final height in [69.0, 120.0, 300.0]) {
      testWidgets(
          'camera placeholder fits $height pixels in $locale at 2x text',
          (tester) async {
        await tester.pumpWidget(MaterialApp(
          locale: locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 240,
                height: height,
                child: const CameraPreviewWidget(
                  frame: null,
                  status: BluetoothStatus.disconnected,
                ),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final context = tester.element(find.byType(CameraPreviewWidget));
        final message = AppLocalizations.of(context).glassesNotConnected;
        expect(find.text(message), findsOneWidget);
        final scroll = find.descendant(
          of: find.byType(CameraPreviewWidget),
          matching: find.byType(Scrollable),
        );
        expect(scroll, findsOneWidget);
        final position = tester.state<ScrollableState>(scroll).position;
        if (position.maxScrollExtent > 0) {
          position.jumpTo(position.maxScrollExtent);
          await tester.pump();
          final viewport = tester.getRect(find.byType(CameraPreviewWidget));
          final text = tester.getRect(find.text(message));
          expect(text.bottom, lessThanOrEqualTo(viewport.bottom));
          expect(text.bottom, greaterThan(viewport.top));
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
}
