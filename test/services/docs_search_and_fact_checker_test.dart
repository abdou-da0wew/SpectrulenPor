import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/models/citation.dart';
import 'package:smart_glass_app/services/docs_search_service.dart';
import 'package:smart_glass_app/services/fact_checker_service.dart';
import 'package:smart_glass_app/services/websearch_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DocsSearchService (119 elements, 110 compounds, 3 search modes)', () {
    test('loads all 3 bundled JSON docs cleanly and guards empty queries',
        () async {
      final docs = DocsSearchService.instance;
      await docs.init();
      expect(docs.isReady, isTrue);

      expect(docs.searchLocal(''), isEmpty);
      expect(docs.searchLocal('   '), isEmpty);

      final helium = docs.searchLocal('Helium');
      expect(helium, isNotEmpty);
      expect(helium.first.title, contains('Helium'));

      final caffeine = docs.searchLocal('Caffeine');
      expect(
        caffeine.where((d) => d.title.startsWith('Caffeine')).length,
        1,
      );

      final corrosive = docs.searchLocal('Corrosive');
      expect(corrosive, isNotEmpty);
    });

    test('strict mode matches exact symbols, formulas & CAS without fuzzy noise',
        () async {
      final docs = DocsSearchService.instance;
      await docs.init();

      final gold = await docs.searchByMode(
        'Au',
        mode: DocsSearchMode.strict,
        allowNetwork: false,
      );
      expect(gold, isNotEmpty);
      expect(gold.first.title, contains('Gold'));
      expect(gold.first.snippet, contains('°C'));

      final boro = await docs.searchByMode(
        'Borosilicate Glass',
        mode: DocsSearchMode.strict,
        allowNetwork: false,
      );
      expect(boro, isNotEmpty);
      expect(boro.first.title, contains('Borosilicate glass'));
    });

    test('detailed mode returns rich atomic, electronic & physical properties',
        () async {
      final docs = DocsSearchService.instance;
      await docs.init();

      final uranium = await docs.searchByMode(
        'Uranium',
        mode: DocsSearchMode.detailed,
        allowNetwork: false,
      );
      expect(uranium, isNotEmpty);
      expect(uranium.first.snippet, contains('Atomic #92'));
      expect(uranium.first.snippet, contains('Electron config'));
    });

    test('semantic mode expands YOLO object labels into constituent materials',
        () async {
      final docs = DocsSearchService.instance;
      await docs.init();

      // YOLO COCO label "bottle" expands semantically to PET / borosilicate glass / water
      final bottleDocs = await docs.searchByMode(
        'bottle',
        mode: DocsSearchMode.semantic,
        allowNetwork: false,
      );
      expect(bottleDocs, isNotEmpty);
      final titles = bottleDocs.map((c) => c.title.toLowerCase()).join(' | ');
      expect(
        titles.contains('polyethylene terephthalate') ||
            titles.contains('borosilicate') ||
            titles.contains('water'),
        isTrue,
      );

      // YOLO COCO label "fork" expands semantically to stainless steel / iron / chromium
      final forkDocs = await docs.searchByMode(
        'fork',
        mode: DocsSearchMode.semantic,
        allowNetwork: false,
      );
      expect(forkDocs, isNotEmpty);
    });

    test('search by CAS Registry Number resolves the exact compound', () async {
      final docs = DocsSearchService.instance;
      await docs.init();

      // Exact formatted CAS (water)
      final byCas = docs.searchLocal('7732-18-5');
      expect(byCas, isNotEmpty);
      // CAS is a unique identifier: the exact compound must be the top hit.
      expect(byCas.first.title, startsWith('Water'));
      // Snippet surfaces the identifier for the AI citation pipeline.
      expect(byCas.first.snippet, contains('CAS: 7732-18-5'));

      // Hyphens/spaces optional: digits-only normalization still matches.
      final loose = docs.searchLocal('7732 18 5');
      expect(loose, isNotEmpty);
      expect(loose.first.title, startsWith('Water'));

      // Unrelated digits must not match a CAS.
      final miss = docs.searchLocal('99999-99-4');
      expect(
        miss.where((d) => d.title.startsWith('Water')),
        isEmpty,
      );

      // Aspirin via CAS.
      final aspirin = docs.searchLocal('50-78-2');
      expect(aspirin, isNotEmpty);
      expect(aspirin.first.title, contains('aspirin'));
    });

    test('bundled corpus CAS numbers are complete and checksum-valid',
        () async {
      final docs = DocsSearchService.instance;
      await docs.init();

      // CAS check digit: body digits weighted right-to-left, mod 10.
      bool casValid(String cas) {
        final digits = cas.replaceAll('-', '');
        if (digits.length < 4 || int.tryParse(digits) == null) return false;
        final check = int.parse(digits[digits.length - 1]);
        var total = 0;
        for (var i = 0; i < digits.length - 1; i++) {
          total += int.parse(digits[i]) * (digits.length - 1 - i);
        }
        return total % 10 == check;
      }

      final raw = await rootBundle
          .loadString('assets/docs/common_compounds.json');
      final compounds =
          (jsonDecode(raw) as List).cast<Map<String, dynamic>>();

      final withCas = compounds.where((c) => c['cas'] != null).toList();
      // 108 of 110 carry a CAS; the 2 true mixtures (glass, steel) do not.
      expect(withCas.length, 108);
      for (final c in withCas) {
        expect(casValid(c['cas'] as String), isTrue,
            reason: '${c['name']}: invalid CAS ${c['cas']}');
      }
      final noCas =
          compounds.where((c) => c['cas'] == null).map((c) => c['name']);
      expect(noCas, containsAll(<String>['Borosilicate glass']));

      // Known anchor values (PubChem CAS Common Chemistry).
      final byName = {for (final c in compounds) c['name'] as String: c};
      expect(byName['Water']!['cas'], '7732-18-5');
      expect(byName['Sodium chloride']!['cas'], '7647-14-5');
      expect(byName['Copper(II) sulfate pentahydrate']!['cas'], '7758-99-8');
      // Hydrates must not collapse into their anhydrous CAS.
      expect(
        byName['Magnesium sulfate heptahydrate (Epsom salt)']!['cas'],
        isNot('7487-88-9'),
      );
      // Mixtures must never inherit a single-component CAS.
      expect(
        byName['Stainless steel (304 austenitic)']!['cas'],
        isNot('7439-89-6'),
        reason: '7439-89-6 is elemental iron, not stainless steel',
      );
      // Mixtures carry an explicit cas_skip flag + human-readable cas_note so
      // the AI layer can state "no single CAS" instead of guessing one.
      expect(byName['Borosilicate glass']!['cas_skip'], isTrue);
      expect(byName['Borosilicate glass']!['cas_note'], isNotEmpty);
      expect(byName['Stainless steel (304 austenitic)']!['cas_skip'], isTrue);
      expect(byName['Stainless steel (304 austenitic)']!['cas_note'], isNotEmpty);
    });

    test('detailed mode surfaces CAS numbers and mixture cas_note for the AI',
        () async {
      final docs = DocsSearchService.instance;
      await docs.init();

      final water = await docs.searchByMode(
        'Water',
        mode: DocsSearchMode.detailed,
        allowNetwork: false,
      );
      expect(water.first.snippet, contains('CAS: 7732-18-5'));

      final steel = await docs.searchByMode(
        'Stainless steel',
        mode: DocsSearchMode.detailed,
        allowNetwork: false,
      );
      final steelDoc = steel.firstWhere(
        (d) => d.title.contains('Stainless steel'),
        orElse: () => steel.first,
      );
      expect(steelDoc.snippet, contains('CAS: not applicable'));
      expect(steelDoc.snippet, contains('Fe-Cr-Ni alloy'));
    });
  });

  group('WebSearchResult.fromRelatedTopic', () {
    test('parses both direct entries and nested Topics groups', () {
      final direct = WebSearchResult.fromRelatedTopic(const {
        'Text': 'Sodium chloride - Ionic crystalline compound NaCl',
        'FirstURL': 'https://duckduckgo.com/Sodium_chloride',
      });
      expect(direct, isNotNull);
      expect(direct!.title, 'Sodium chloride');
      expect(direct.url, 'https://duckduckgo.com/Sodium_chloride');

      final nested = WebSearchResult.fromRelatedTopic(const {
        'Name': 'Chemistry',
        'Topics': [
          {
            'Text': 'Halite - Mineral form of sodium chloride',
            'FirstURL': 'https://duckduckgo.com/Halite',
          }
        ],
      });
      expect(nested, isNotNull);
      expect(nested!.title, 'Halite');
    });
  });

  group('FactCheckerService', () {
    test('verifies English & Arabic factual claims against sources', () async {
      final checker = FactCheckerService.instance;
      const sources = [
        Citation(
          index: 1,
          title: 'Water (H2O)',
          url: 'https://en.wikipedia.org/wiki/Water',
          snippet:
              'Formula: H2O · Molar mass: 18.015 g/mol · Boiling point: 100 °C · neutral pH 7',
          type: CitationType.bundledDoc,
        ),
        Citation(
          index: 2,
          title: 'الماء',
          url: 'https://ar.wikipedia.org/wiki/%D9%85%D8%A7%D8%A1',
          snippet: 'الماء مركب كيميائي صيغته H2O ودرجة غليان الماء 100 مئوية',
          type: CitationType.wikipedia,
        ),
      ];

      final enRes = await checker.check(
        llmMarkdown:
            'Water has formula H2O and boiling point 100 °C. Pure water has neutral pH 7.',
        sources: sources,
      );
      expect(enRes.verifiedCount, greaterThanOrEqualTo(2));
      expect(enRes.annotatedMarkdown, contains('[VERIFIED 1]'));

      final arRes = await checker.check(
        llmMarkdown: 'الماء مركب كيميائي ودرجة غليان الماء 100 مئوية.',
        sources: sources,
      );
      expect(arRes.verifiedCount, 1);
      expect(arRes.annotatedMarkdown, contains('[VERIFIED 2]'));
    });
  });
}
