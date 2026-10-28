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
      expect(boro.first.title, contains('Borosilicate Glass'));
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
