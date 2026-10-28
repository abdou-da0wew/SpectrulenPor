import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_glass_app/main.dart';
import 'package:smart_glass_app/models/bounding_box.dart';
import 'package:smart_glass_app/services/docs_search_service.dart';
import 'package:smart_glass_app/services/internal_db_service.dart';
import 'package:smart_glass_app/widgets/bounding_box_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'BoundingBoxOverlay renders boxes, locks SELECTED marker on tap, and deselects on second tap',
      (tester) async {
    BoundingBox? selected;
    const boxes = [
      BoundingBox(
        x: 0.15,
        y: 0.20,
        w: 0.35,
        h: 0.40,
        label: 'beaker',
        confidence: 0.92,
      ),
      BoundingBox(
        x: 0.60,
        y: 0.25,
        w: 0.25,
        h: 0.35,
        label: 'bottle',
        confidence: 0.84,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: StatefulBuilder(
              builder: (context, setState) => BoundingBoxOverlay(
                boxes: boxes,
                selected: selected,
                sourceAspectRatio: 0.75,
                onSelect: (b) => setState(() => selected = b),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('beaker 92%'), findsOneWidget);
    expect(find.text('bottle 84%'), findsOneWidget);
    expect(find.textContaining('SELECTED ·'), findsNothing);

    // Tap beaker -> locks target marker
    await tester.tap(find.text('beaker 92%'));
    await tester.pumpAndSettle();
    expect(selected?.label, 'beaker');
    expect(find.text('SELECTED · beaker 92%'), findsOneWidget);

    // Tap selected beaker again -> clears selection
    await tester.tap(find.text('SELECTED · beaker 92%'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(find.text('beaker 92%'), findsOneWidget);
  });

  testWidgets(
      'HomeScreen enforces strict Capture button gating & navigates to History and Diagnostics',
      (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    await InternalDatabaseService.instance.init();
    await DocsSearchService.instance.init();
    appLocale.value = const Locale('en');

    await tester.pumpWidget(SpectruLenPorApp(prefs: prefs, secrets: const {}));
    await tester.pump(const Duration(milliseconds: 400));

    // Capture button is disabled when no YOLO box is selected
    expect(
      find.text('Select a YOLO Box on Camera to Capture'),
      findsOneWidget,
    );

    // Open History & Scientific Docs screen
    await tester.tap(find.byTooltip('History & Scientific Docs'));
    await tester.pumpAndSettle();
    expect(find.text('History & Scientific Docs'), findsOneWidget);
    expect(find.text('Saved Chats'), findsOneWidget);
    expect(find.text('Knowledge Docs'), findsOneWidget);

    // Navigate back to Home -> open Settings -> verify Cloud-only toggle & Search Mode
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(
      find.text('Cloud-only models (except YOLO26-Nano)'),
      findsOneWidget,
    );
    expect(find.text('Strict'), findsOneWidget);
    expect(find.text('Detailed'), findsOneWidget);
    expect(find.text('Semantic'), findsOneWidget);

    // Open Internal DB & Diagnostics screen from Settings
    await tester.scrollUntilVisible(
      find.text('Database, Cache, Logs, Hangs & Traces'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Database, Cache, Logs, Hangs & Traces'));
    await tester.pumpAndSettle();
    expect(find.text('Internal DB & Diagnostics'), findsOneWidget);
    expect(find.text('Table Row Counts (9 Tables)'), findsOneWidget);
  });
}
