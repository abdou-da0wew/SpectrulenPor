import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/citation.dart';
import 'internal_db_service.dart';
import 'pubchem_service.dart';
import 'websearch_service.dart';
import 'wikipedia_service.dart';

/// Search modes supported across in-app docs, Wikipedia, PubChem, and Web:
///   * [strict]   — exact symbol / formula / atomic number / GHS ID / name match
///   * [detailed] — exhaustive multi-property match (all 26 element fields +
///                  compound physical/safety properties + PubChem + Wikipedia)
///   * [semantic] — concept/synonym/YOLO-object-to-material expansion + fuzzy
///                  trigram/token similarity + bundled docs + Wikipedia +
///                  PubChem + DuckDuckGo web search
enum DocsSearchMode { strict, detailed, semantic }

/// Combined scientific knowledge base + multi-mode search engine:
///   1. Periodic table (`assets/docs/periodic_table.json` — all 118+ elements
///      with 26 physical, atomic, electronic, and historical fields)
///   2. Common compounds & real-world materials (`assets/docs/common_compounds.json`
///      — 110 compounds, alloys, polymers, indicators, and biomolecules)
///   3. Lab safety (`assets/docs/lab_safety.json` — GHS01–GHS09 pictograms,
///      PPE protocols, emergency procedures)
///   4. Live Wikipedia REST API + NCBI PubChem PUG REST + DuckDuckGo Web Search
///      (backed by persistent TTL caching in [InternalDatabaseService]).
class DocsSearchService {
  DocsSearchService._();
  static final DocsSearchService instance = DocsSearchService._();

  bool _loaded = false;
  List<Map<String, dynamic>> _elements = const [];
  List<Map<String, dynamic>> _compounds = const [];
  Map<String, dynamic> _safety = const {};

  bool get isLoaded => _loaded;
  bool get isReady => _loaded;
  int get elementCount => _elements.length;
  int get compoundCount => _compounds.length;

  /// Concept & YOLO-label expansion map for semantic search: maps everyday
  /// detected COCO objects and colloquial terms to their underlying chemical
  /// elements, compounds, alloys, polymers, and lab glassware materials.
  static const Map<String, List<String>> _semanticExpansions = {
    'bottle': [
      'borosilicate glass',
      'polyethylene terephthalate',
      'water',
      'silicon dioxide',
      'ethanol',
    ],
    'wine glass': ['borosilicate glass', 'silicon dioxide', 'ethanol', 'tartaric acid'],
    'cup': ['borosilicate glass', 'water', 'caffeine', 'silicon dioxide', 'sucrose'],
    'bowl': ['borosilicate glass', 'silicon dioxide', 'sodium chloride', 'water'],
    'fork': ['stainless steel', 'iron', 'chromium', 'nickel'],
    'knife': ['stainless steel', 'iron', 'chromium', 'carbon'],
    'spoon': ['stainless steel', 'iron', 'chromium', 'silver'],
    'scissors': ['stainless steel', 'iron', 'chromium'],
    'cell phone': [
      'lithium cobalt oxide',
      'indium tin oxide',
      'silicon',
      'aluminum',
      'lithium',
    ],
    'laptop': [
      'lithium cobalt oxide',
      'silicon',
      'aluminum',
      'copper',
      'polycarbonate',
    ],
    'tv': ['indium tin oxide', 'silicon', 'gallium', 'indium'],
    'keyboard': ['polycarbonate', 'polypropylene', 'copper', 'silicon'],
    'mouse': ['polycarbonate', 'polypropylene', 'silicon'],
    'remote': ['polypropylene', 'manganese dioxide', 'zinc', 'silicon'],
    'book': ['cellulose', 'carbon', 'calcium carbonate', 'titanium dioxide'],
    'potted plant': ['chlorophyll a', 'cellulose', 'water', 'carbon dioxide', 'magnesium'],
    'vase': ['silicon dioxide', 'borosilicate glass', 'aluminum oxide', 'water'],
    'apple': ['ascorbic acid', 'malic acid', 'glucose', 'water', 'potassium'],
    'orange': ['citric acid', 'ascorbic acid', 'glucose', 'water'],
    'banana': ['potassium', 'glucose', 'sucrose', 'ascorbic acid'],
    'broccoli': ['ascorbic acid', 'chlorophyll a', 'calcium', 'iron'],
    'carrot': ['glucose', 'cellulose', 'potassium', 'water'],
    'cake': ['sucrose', 'sodium bicarbonate', 'glucose'],
    'donut': ['sucrose', 'glucose', 'sodium bicarbonate'],
    'sink': ['stainless steel', 'water', 'sodium hypochlorite', 'calcium carbonate'],
    'refrigerator': ['stainless steel', 'aluminum', 'copper', 'polypropylene'],
    'microwave': ['stainless steel', 'borosilicate glass', 'copper'],
    'oven': ['stainless steel', 'iron', 'borosilicate glass'],
    'clock': ['silicon dioxide', 'quartz', 'copper', 'lithium'],
    'toothbrush': ['polypropylene', 'fluorine', 'calcium carbonate'],
    'salt': ['sodium chloride'],
    'table salt': ['sodium chloride'],
    'baking soda': ['sodium bicarbonate'],
    'vinegar': ['acetic acid'],
    'bleach': ['sodium hypochlorite'],
    'rubbing alcohol': ['isopropanol'],
    'rust': ['iron(iii) oxide', 'iron'],
    'chalk': ['calcium carbonate'],
    'limestone': ['calcium carbonate'],
    'sand': ['silicon dioxide'],
    'quartz': ['silicon dioxide'],
    'glass': ['borosilicate glass', 'silicon dioxide'],
    'sugar': ['sucrose', 'glucose'],
    'aspirin': ['acetylsalicylic acid'],
    'vitamin c': ['ascorbic acid'],
    'epsom salt': ['magnesium sulfate'],
    'lye': ['sodium hydroxide'],
    'caustic soda': ['sodium hydroxide'],
    'battery': ['lithium cobalt oxide', 'lithium iron phosphate', 'sulfuric acid', 'zinc'],
    'steel': ['stainless steel', 'iron', 'chromium', 'carbon'],
  };

  Future<void> init() async {
    if (_loaded) return;
    var anyLoaded = false;

    try {
      final elementsJson =
          await rootBundle.loadString('assets/docs/periodic_table.json');
      _elements =
          (jsonDecode(elementsJson) as List).cast<Map<String, dynamic>>();
      anyLoaded = true;
    } catch (e) {
      debugPrint('[DocsSearch] periodic_table.json load failed: $e');
    }

    try {
      final compoundsJson =
          await rootBundle.loadString('assets/docs/common_compounds.json');
      _compounds =
          (jsonDecode(compoundsJson) as List).cast<Map<String, dynamic>>();
      anyLoaded = true;
    } catch (e) {
      debugPrint('[DocsSearch] common_compounds.json load failed: $e');
    }

    try {
      final safetyJson =
          await rootBundle.loadString('assets/docs/lab_safety.json');
      _safety = jsonDecode(safetyJson) as Map<String, dynamic>;
      anyLoaded = true;
    } catch (e) {
      debugPrint('[DocsSearch] lab_safety.json load failed: $e');
    }

    _loaded = anyLoaded;
    if (_loaded) {
      debugPrint(
        '[DocsSearch] loaded ${_elements.length} elements, '
        '${_compounds.length} compounds, '
        '${(_safety['pictograms'] as List?)?.length ?? 0} hazard pictograms',
      );
    }
  }

  /// Dispatch search according to [mode] (`strict`, `detailed`, or `semantic`).
  Future<List<Citation>> searchByMode(
    String query, {
    DocsSearchMode mode = DocsSearchMode.semantic,
    int startIndex = 1,
    int limit = 6,
    String lang = 'en',
    bool allowNetwork = true,
  }) {
    return switch (mode) {
      DocsSearchMode.strict => searchStrict(query, startIndex: startIndex),
      DocsSearchMode.detailed => searchDetailed(
          query,
          startIndex: startIndex,
          limit: limit,
          lang: lang,
          allowNetwork: allowNetwork,
        ),
      DocsSearchMode.semantic => searchSemantic(
          query,
          startIndex: startIndex,
          limit: limit,
          lang: lang,
          fetchWiki: allowNetwork,
          fetchPubChem: allowNetwork,
          fetchWeb: allowNetwork,
        ),
    };
  }

  /// Synchronous offline search over the bundled elements, compounds, and
  /// lab-safety JSON documents (zero network calls).
  List<Citation> searchLocal(
    String query, {
    int startIndex = 1,
    int limit = 6,
    bool detailed = true,
  }) {
    final trimmed = query.trim();
    if (trimmed.isEmpty || !_loaded) return const [];
    final hits = _scoreBundledDocs(trimmed, detailedSnippets: detailed);
    return _rankAndConvert(hits, startIndex: startIndex, limit: limit);
  }

  /// Combined default search (local docs + optional Wikipedia fallback).
  Future<List<Citation>> search(
    String query, {
    int startIndex = 1,
    bool fetchWiki = true,
    String lang = 'en',
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    if (!_loaded) await init();

    final results = _scoreBundledDocs(trimmed, detailedSnippets: true);

    if (fetchWiki && results.where((r) => r.score > 0.7).isEmpty) {
      final wiki = await WikipediaService.instance
          .searchWithSummaries(trimmed, limit: 3, lang: lang);
      for (final w in wiki) {
        results.add(_DocHit(
          title: w.title,
          snippet: w.snippet,
          score: 0.72,
          type: CitationType.wikipedia,
          url: w.url,
          thumbnailUrl: w.thumbnailUrl,
        ));
      }
    }

    return _rankAndConvert(results, startIndex: startIndex, limit: 6);
  }

  // ---------------------------------------------------------------------------
  // MODE 1: STRICT SEARCH — exact symbol / formula / atomic # / GHS / name
  // ---------------------------------------------------------------------------

  Future<List<Citation>> searchStrict(
    String query, {
    int startIndex = 1,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    if (!_loaded) await init();
    final qLower = q.toLowerCase();
    final atomicNumQuery =
        int.tryParse(q.startsWith('#') ? q.substring(1).trim() : q);

    final results = <_DocHit>[];
    for (final e in _elements) {
      final sym = (e['sym'] as String?) ?? '';
      final name = (e['name'] as String?) ?? '';
      final numVal = (e['num'] as num?)?.toInt();
      if (sym == q ||
          name.toLowerCase() == qLower ||
          (atomicNumQuery != null && numVal == atomicNumQuery)) {
        results.add(_DocHit(
          title: '$name ($sym, #$numVal)',
          snippet: _formatElementDetailed(e),
          score: 1.0,
          type: CitationType.bundledDoc,
          url: (e['source'] as String?) ?? '',
        ));
      }
    }

    for (final c in _compounds) {
      final formula = (c['formula'] as String?) ?? '';
      final name = (c['name'] as String?) ?? '';
      if (formula == q ||
          formula.toLowerCase() == qLower ||
          name.toLowerCase() == qLower) {
        results.add(_DocHit(
          title: '$name ($formula)',
          snippet: _formatCompoundDetailed(c),
          score: 1.0,
          type: CitationType.bundledDoc,
        ));
      }
    }

    final pictos = (_safety['pictograms'] as List?) ?? const [];
    for (final p in pictos.whereType<Map<String, dynamic>>()) {
      final id = (p['id'] as String?) ?? '';
      final name = (p['name'] as String?) ?? '';
      if (id.toLowerCase() == qLower || name.toLowerCase() == qLower) {
        results.add(_DocHit(
          title: 'Hazard: $name ($id)',
          snippet: _formatSafetyPictogram(p),
          score: 1.0,
          type: CitationType.bundledDoc,
        ));
      }
    }

    return _rankAndConvert(results, startIndex: startIndex, limit: 4);
  }

  // ---------------------------------------------------------------------------
  // MODE 2: DETAILED SEARCH — deep multi-property + PubChem + Wikipedia
  // ---------------------------------------------------------------------------

  Future<List<Citation>> searchDetailed(
    String query, {
    int startIndex = 1,
    int limit = 8,
    String lang = 'en',
    bool allowNetwork = true,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    if (!_loaded) await init();

    final results = _scoreBundledDocs(trimmed, detailedSnippets: true);

    if (allowNetwork) {
      final pcFuture = PubChemService.instance.lookupByName(trimmed);
      final wikiFuture = WikipediaService.instance
          .searchWithSummaries(trimmed, limit: 3, lang: lang);

      final pc = await pcFuture;
      if (pc != null) {
        results.add(_DocHit(
          title:
              'PubChem: ${pc.iupacName ?? pc.name ?? pc.molecularFormula} (${pc.molecularFormula})',
          snippet: pc.summary,
          score: 0.94,
          type: CitationType.pubchem,
          url: pc.pubchemUrl,
        ));
      }

      final wiki = await wikiFuture;
      for (final w in wiki) {
        results.add(_DocHit(
          title: w.title,
          snippet: w.snippet,
          score: 0.78,
          type: CitationType.wikipedia,
          url: w.url,
          thumbnailUrl: w.thumbnailUrl,
        ));
      }
    }

    return _rankAndConvert(results, startIndex: startIndex, limit: limit);
  }

  // ---------------------------------------------------------------------------
  // MODE 3: SEMANTIC SEARCH — concept/object expansion + fuzzy + 4-tier sources
  // ---------------------------------------------------------------------------

  Future<List<Citation>> searchSemantic(
    String query, {
    int startIndex = 1,
    int limit = 6,
    String lang = 'en',
    bool fetchWiki = true,
    bool fetchPubChem = true,
    bool fetchWeb = true,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    if (!_loaded) await init();

    final q = trimmed.toLowerCase();
    final results = <_DocHit>[];

    // Direct + fuzzy scoring on the raw query.
    results.addAll(_scoreBundledDocs(trimmed, detailedSnippets: true, fuzzy: true));

    // Concept / YOLO-label semantic expansion (e.g. "cup" -> Borosilicate glass, Water, Caffeine).
    final expandedTerms = <String>{};
    _semanticExpansions.forEach((key, mapped) {
      if (q == key || q.contains(key)) {
        expandedTerms.addAll(mapped);
      }
    });
    for (final term in expandedTerms) {
      for (final hit in _scoreBundledDocs(term, detailedSnippets: true)) {
        results.add(_DocHit(
          title: hit.title,
          snippet: hit.snippet,
          score: (hit.score * 0.82).clamp(0.45, 0.92),
          type: hit.type,
          url: hit.url,
        ));
      }
    }

    // Parallel external enrichment (PubChem + Wikipedia + DuckDuckGo Web Search)
    final needWiki = fetchWiki && results.where((r) => r.score > 0.85).length < 3;
    final needPubChem = fetchPubChem;
    final primaryLookupTerm =
        expandedTerms.isNotEmpty && results.where((r) => r.score > 0.9).isEmpty
            ? expandedTerms.first
            : trimmed;

    if (needWiki || needPubChem) {
      final futures = <Future<void>>[];
      if (needPubChem) {
        futures.add(() async {
          var pc = await PubChemService.instance.lookupByName(trimmed);
          pc ??= primaryLookupTerm != trimmed
              ? await PubChemService.instance.lookupByName(primaryLookupTerm)
              : null;
          if (pc != null) {
            results.add(_DocHit(
              title:
                  'PubChem: ${pc.iupacName ?? pc.name ?? pc.molecularFormula} (${pc.molecularFormula})',
              snippet: pc.summary,
              score: 0.92,
              type: CitationType.pubchem,
              url: pc.pubchemUrl,
            ));
          }
        }());
      }
      if (needWiki) {
        futures.add(() async {
          final wiki = await WikipediaService.instance
              .searchWithSummaries(trimmed, limit: 3, lang: lang);
          for (final w in wiki) {
            results.add(_DocHit(
              title: w.title,
              snippet: w.snippet,
              score: 0.74,
              type: CitationType.wikipedia,
              url: w.url,
              thumbnailUrl: w.thumbnailUrl,
            ));
          }
        }());
      }
      await Future.wait(futures);
    }

    if (fetchWeb && results.length < limit) {
      final ws = await WebSearchService.instance
          .search(trimmed, limit: math.max(2, limit - results.length));
      for (final w in ws) {
        if (w.snippet.trim().isEmpty) continue;
        results.add(_DocHit(
          title: w.title.isNotEmpty ? w.title : 'Web reference',
          snippet: w.snippet,
          score: 0.56,
          type: CitationType.web,
          url: w.url,
          thumbnailUrl: w.thumbnailUrl,
        ));
      }
    }

    unawaited(InternalDatabaseService.instance.recordActivity(
      'docs_search',
      target: trimmed,
      details: {'mode': 'semantic', 'hits': results.length},
    ));

    return _rankAndConvert(results, startIndex: startIndex, limit: limit);
  }

  // ---------------------------------------------------------------------------
  // BUNDLED SCORING & PROPERTY FORMATTERS
  // ---------------------------------------------------------------------------

  List<_DocHit> _scoreBundledDocs(
    String rawQuery, {
    bool detailedSnippets = true,
    bool fuzzy = false,
  }) {
    final q = rawQuery.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final words =
        q.split(RegExp(r'[\s,;/()]+')).where((w) => w.length >= 2).toList();
    final hits = <_DocHit>[];

    // 1. All 118+ elements
    for (final e in _elements) {
      final sym = (e['sym'] as String?)?.toLowerCase() ?? '';
      final name = (e['name'] as String?)?.toLowerCase() ?? '';
      final summary = (e['summary'] as String?)?.toLowerCase() ?? '';
      final appearance = (e['appearance'] as String?)?.toLowerCase() ?? '';
      final category = (e['category'] as String?)?.toLowerCase() ?? '';
      final phase = (e['phase'] as String?)?.toLowerCase() ?? '';
      final discoveredBy = (e['discovered_by'] as String?)?.toLowerCase() ?? '';
      final eConfig =
          (e['electron_configuration_semantic'] as String?)?.toLowerCase() ?? '';
      final numStr = e['num']?.toString() ?? '';

      double score = 0;
      if (sym.isNotEmpty && sym == q) {
        score = 1.0;
      } else if (name.isNotEmpty && name == q) {
        score = 1.0;
      } else if (q == '#$numStr') {
        score = 0.98;
      } else if (name.isNotEmpty && (name.contains(q) || q.contains(name))) {
        score = 0.88;
      } else if (sym.isNotEmpty && words.contains(sym)) {
        score = 0.92;
      } else if (eConfig.isNotEmpty && eConfig == q) {
        score = 0.85;
      } else if (discoveredBy.isNotEmpty && discoveredBy.contains(q)) {
        score = 0.72;
      } else if (appearance.isNotEmpty &&
          q.length >= 4 &&
          (appearance.contains(q) || q.contains(appearance))) {
        score = 0.58;
      } else if (category.isNotEmpty &&
          q.length >= 4 &&
          (category.contains(q) || q.contains(category))) {
        score = 0.55;
      } else if (words.isNotEmpty &&
          words.any((w) => w.length >= 3 && (name == w || name.startsWith(w)))) {
        score = 0.78;
      } else if (words.isNotEmpty &&
          words.where((w) => w.length >= 4).any(summary.contains)) {
        score = 0.52;
      } else if (phase.isNotEmpty && q == phase) {
        score = 0.35;
      } else if (fuzzy && name.isNotEmpty && q.length >= 4) {
        final sim = _trigramSimilarity(q, name);
        if (sim >= 0.48) score = 0.5 + sim * 0.3;
      }

      if (score > 0) {
        hits.add(_DocHit(
          title: '${e['name']} (${e['sym']}, #${e['num']})',
          snippet: detailedSnippets
              ? _formatElementDetailed(e)
              : ((e['summary'] as String?) ?? ''),
          score: score,
          type: CitationType.bundledDoc,
          url: (e['source'] as String?) ?? '',
        ));
      }
    }

    // 2. All 110 compounds & materials
    for (final c in _compounds) {
      final formula = (c['formula'] as String?)?.toLowerCase() ?? '';
      final name = (c['name'] as String?)?.toLowerCase() ?? '';
      final color = (c['color'] as String?)?.toLowerCase() ?? '';
      final state = (c['state'] as String?)?.toLowerCase() ?? '';
      final summary = (c['summary'] as String?)?.toLowerCase() ?? '';
      final uses = (c['uses'] as List?)
              ?.map((u) => u.toString().toLowerCase())
              .join(' ') ??
          '';
      final hazards = (c['hazards'] as List?)
              ?.map((h) => h.toString().toLowerCase())
              .join(' ') ??
          '';

      double score = 0;
      if (formula.isNotEmpty && formula == q) {
        score = 0.99;
      } else if (name.isNotEmpty && name == q) {
        score = 0.98;
      } else if (formula.isNotEmpty &&
          q.length >= 2 &&
          (formula.startsWith(q) || formula.contains(q))) {
        score = 0.90;
      } else if (name.isNotEmpty && (name.contains(q) || q.contains(name))) {
        score = 0.87;
      } else if (words.isNotEmpty &&
          words.where((w) => w.length >= 4).any((w) => name.contains(w))) {
        score = 0.76;
      } else if (color.isNotEmpty &&
          q.length >= 4 &&
          (color.contains(q) || q.contains(color))) {
        score = 0.62;
      } else if (uses.isNotEmpty && q.length >= 3 && uses.contains(q)) {
        score = 0.64;
      } else if (hazards.isNotEmpty && q.length >= 4 && hazards.contains(q)) {
        score = 0.56;
      } else if (summary.isNotEmpty && q.length >= 4 && summary.contains(q)) {
        score = 0.54;
      } else if (words.isNotEmpty &&
          words
              .where((w) => w.length >= 4)
              .any((w) => uses.contains(w) || summary.contains(w))) {
        score = 0.50;
      } else if (state.isNotEmpty && q == state) {
        score = 0.35;
      } else if (fuzzy && name.isNotEmpty && q.length >= 4) {
        final sim = _trigramSimilarity(q, name);
        if (sim >= 0.45) score = 0.48 + sim * 0.32;
      }

      if (score > 0) {
        hits.add(_DocHit(
          title: '${c['name']} (${c['formula']})',
          snippet: _formatCompoundDetailed(c),
          score: score,
          type: CitationType.bundledDoc,
        ));
      }
    }

    // 3. Lab safety pictograms + PPE
    final pictos = (_safety['pictograms'] as List?) ?? const [];
    for (final p in pictos.whereType<Map<String, dynamic>>()) {
      final id = (p['id'] as String?)?.toLowerCase() ?? '';
      final name = (p['name'] as String?)?.toLowerCase() ?? '';
      final summary = (p['summary'] as String?)?.toLowerCase() ?? '';
      if ((id.isNotEmpty && id == q) ||
          (name.isNotEmpty && (name.contains(q) || q.contains(name))) ||
          (q.length >= 4 && summary.contains(q))) {
        hits.add(_DocHit(
          title: 'Hazard: ${p['name']} (${p['id']})',
          snippet: _formatSafetyPictogram(p),
          score: id == q ? 0.95 : 0.66,
          type: CitationType.bundledDoc,
        ));
      }
    }

    final ppeList = (_safety['generalPPE'] as List?) ?? const [];
    for (final item in ppeList.whereType<Map<String, dynamic>>()) {
      final ppeName = (item['item'] as String?)?.toLowerCase() ?? '';
      final purpose = (item['purpose'] as String?)?.toLowerCase() ?? '';
      if (q.length >= 4 && (ppeName.contains(q) || purpose.contains(q))) {
        hits.add(_DocHit(
          title: 'Lab PPE: ${item['item']}',
          snippet: (item['purpose'] as String?) ?? '',
          score: 0.58,
          type: CitationType.bundledDoc,
        ));
      }
    }

    return hits;
  }

  static String _formatElementDetailed(Map<String, dynamic> e) {
    final parts = <String>[];
    parts.add('Atomic #${e['num']}, Symbol ${e['sym']}, Mass ${e['mass']} u');
    if (e['category'] != null) parts.add('Category: ${e['category']}');
    if (e['phase'] != null) parts.add('Phase (STP): ${e['phase']}');
    if (e['appearance'] != null) parts.add('Appearance: ${e['appearance']}');
    if (e['period'] != null || e['group'] != null || e['block'] != null) {
      parts.add(
        'Period ${e['period'] ?? "—"}, Group ${e['group'] ?? "—"}, ${e['block'] ?? ""}-block',
      );
    }
    if (e['density'] != null) {
      parts.add('Density: ${e['density']} ${e['density_unit'] ?? "g/cm³"}');
    }
    if (e['melt_K'] is num) {
      final mk = (e['melt_K'] as num).toDouble();
      final mc = (mk - 273.15).toStringAsFixed(2);
      parts.add('Melting point: $mk K ($mc °C)');
    }
    if (e['boil_K'] is num) {
      final bk = (e['boil_K'] as num).toDouble();
      final bc = (bk - 273.15).toStringAsFixed(2);
      parts.add('Boiling point: $bk K ($bc °C)');
    }
    if (e['electron_configuration_semantic'] != null) {
      parts.add('Electron config: ${e['electron_configuration_semantic']}');
    }
    if (e['electronegativity_pauling'] != null) {
      parts.add('Electronegativity (Pauling): ${e['electronegativity_pauling']}');
    }
    if (e['discovered_by'] != null) {
      parts.add('Discovered by: ${e['discovered_by']}');
    }
    final summary = (e['summary'] as String?) ?? '';
    return '${parts.join(' · ')}. $summary'.trim();
  }

  static String _formatCompoundDetailed(Map<String, dynamic> c) {
    final parts = <String>[];
    if (c['formula'] != null) parts.add('Formula: ${c['formula']}');
    if (c['state'] != null) parts.add('State: ${c['state']}');
    if (c['color'] != null) parts.add('Color: ${c['color']}');
    if (c['density_g_cm3'] != null) {
      parts.add('Density: ${c['density_g_cm3']} g/cm³');
    }
    if (c['melting_C'] != null) parts.add('Melting point: ${c['melting_C']} °C');
    if (c['boiling_C'] != null) parts.add('Boiling point: ${c['boiling_C']} °C');
    final summary = (c['summary'] as String?) ?? '';
    final uses = (c['uses'] as List?)?.join(', ') ?? '';
    final hazards = (c['hazards'] as List?)?.join(', ') ?? '';
    final tail = <String>[
      if (summary.isNotEmpty) summary,
      if (uses.isNotEmpty) 'Uses: $uses.',
      if (hazards.isNotEmpty) 'Hazards: $hazards.',
    ].join(' ');
    return '${parts.join(' · ')}. $tail'.trim();
  }

  static String _formatSafetyPictogram(Map<String, dynamic> p) {
    final summary = (p['summary'] as String?) ?? '';
    final examples = (p['examples'] as List?)?.join(', ') ?? '';
    final action = (p['firstAid'] ?? p['precautions'])?.toString() ?? '';
    return [
      if (summary.isNotEmpty) summary,
      if (examples.isNotEmpty) 'Examples: $examples.',
      if (action.isNotEmpty) 'Safety: $action',
    ].join(' ');
  }

  static double _trigramSimilarity(String a, String b) {
    Set<String> trigrams(String s) {
      final padded = '  $s ';
      final out = <String>{};
      for (var i = 0; i <= padded.length - 3; i++) {
        out.add(padded.substring(i, i + 3));
      }
      return out;
    }

    final ta = trigrams(a);
    final tb = trigrams(b);
    if (ta.isEmpty || tb.isEmpty) return 0;
    final inter = ta.intersection(tb).length;
    final union = ta.union(tb).length;
    return union == 0 ? 0 : inter / union;
  }

  List<Citation> _rankAndConvert(
    List<_DocHit> results, {
    required int startIndex,
    required int limit,
  }) {
    results.sort((a, b) => b.score.compareTo(a.score));
    final seen = <String>{};
    final deduped = results.where((r) {
      final key = r.title.toLowerCase();
      if (seen.contains(key)) return false;
      seen.add(key);
      return true;
    }).take(limit).toList(growable: false);

    var i = startIndex;
    return deduped.map((h) {
      return Citation(
        index: i++,
        title: h.title,
        url: h.url,
        snippet: h.snippet,
        thumbnailUrl: h.thumbnailUrl,
        type: h.type,
      );
    }).toList(growable: false);
  }
}

class _DocHit {
  final String title;
  final String snippet;
  final double score;
  final CitationType type;
  final String url;
  final String? thumbnailUrl;

  const _DocHit({
    required this.title,
    required this.snippet,
    required this.score,
    required this.type,
    this.url = '',
    this.thumbnailUrl,
  });
}
