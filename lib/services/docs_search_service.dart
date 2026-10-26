import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/citation.dart';
import 'wikipedia_service.dart';
import 'pubchem_service.dart';
import 'websearch_service.dart';

/// Combined in-app docs search: bundled assets + Wikipedia.
///
/// Looks up:
///   1. Periodic table entries (element symbol/name match)
///   2. Common compounds (formula/name match)
///   3. Lab safety pictograms + PPE
///   4. (Optional) Wikipedia summary for the top hit
///
/// Returns a ranked [List<Citation>] ready for the LLM prompt — the caller
/// numbers them [1], [2], [3], etc.
class DocsSearchService {
  DocsSearchService._();
  static final DocsSearchService instance = DocsSearchService._();

  bool _loaded = false;
  List<Map<String, dynamic>> _elements = const [];
  List<Map<String, dynamic>> _compounds = const [];
  Map<String, dynamic> _safety = const {};

  Future<void> init() async {
    if (_loaded) return;
    try {
      final elementsJson = await rootBundle.loadString('assets/docs/periodic_table.json');
      _elements = (jsonDecode(elementsJson) as List).cast<Map<String, dynamic>>();
      final compoundsJson = await rootBundle.loadString('assets/docs/common_compounds.json');
      _compounds = (jsonDecode(compoundsJson) as List).cast<Map<String, dynamic>>();
      final safetyJson = await rootBundle.loadString('assets/docs/lab_safety.json');
      _safety = jsonDecode(safetyJson) as Map<String, dynamic>;
      _loaded = true;
      debugPrint('[DocsSearch] loaded ${_elements.length} elements, '
          '${_compounds.length} compounds, ${(_safety['pictograms'] as List?)?.length ?? 0} hazard pictograms');
    } catch (e) {
      debugPrint('[DocsSearch] init failed (assets may be missing): $e');
    }
  }

  /// Combined search — returns ranked [Citation]s. Each call generates the
  /// citation index from [startIndex].
  Future<List<Citation>> search(String query, {int startIndex = 1, bool fetchWiki = true}) async {
    if (!_loaded) await init();
    final results = <_DocHit>[];
    final q = query.toLowerCase();

    // 1. Periodic table.
    for (final e in _elements) {
      final sym = (e['sym'] as String?)?.toLowerCase() ?? '';
      final name = (e['name'] as String?)?.toLowerCase() ?? '';
      double score = 0;
      if (sym == q) score = 1.0;
      else if (name.contains(q) || q.contains(name)) score = 0.8;
      else if (sym.isNotEmpty && q.contains(sym)) score = 0.5;
      if (score > 0) {
        results.add(_DocHit(
          title: '${e['name']} (${e['sym']}, #${e['num']})',
          snippet: (e['summary'] as String?) ?? '',
          score: score,
          type: CitationType.bundledDoc,
        ));
      }
    }

    // 2. Common compounds.
    for (final c in _compounds) {
      final formula = (c['formula'] as String?)?.toLowerCase() ?? '';
      final name = (c['name'] as String?)?.toLowerCase() ?? '';
      double score = 0;
      if (formula.startsWith(q) || formula.contains(q)) score = 0.9;
      else if (name.contains(q) || q.contains(name)) score = 0.85;
      else if (formula.split(' ').any((part) => part.toLowerCase() == q)) score = 0.95;
      if (score > 0) {
        final summary = (c['summary'] as String?) ?? '';
        final uses = (c['uses'] as List?)?.join(', ') ?? '';
        final hazards = (c['hazards'] as List?)?.join(', ') ?? '';
        results.add(_DocHit(
          title: '${c['name']} (${c['formula']})',
          snippet: '$summary Uses: $uses. Hazards: $hazards.',
          score: score,
          type: CitationType.bundledDoc,
        ));
      }
    }

    // 3. Lab safety pictograms.
    final pictos = (_safety['pictograms'] as List?) ?? const [];
    for (final p in pictos.whereType<Map<String, dynamic>>()) {
      final name = (p['name'] as String?)?.toLowerCase() ?? '';
      if (name.contains(q) || q.contains(name)) {
        results.add(_DocHit(
          title: 'Hazard: ${p['name']} (${p['id']})',
          snippet: (p['summary'] as String?) ?? '',
          score: 0.6,
          type: CitationType.bundledDoc,
        ));
      }
    }

    // 4. Wikipedia (optional, only if no strong in-app hit).
    if (fetchWiki && results.where((r) => r.score > 0.7).isEmpty) {
      final wiki = await WikipediaService.instance.searchWithSummaries(query, limit: 3);
      for (final w in wiki) {
        results.add(_DocHit(
          title: w.title,
          snippet: w.snippet,
          score: 0.7,
          type: CitationType.wikipedia,
          url: w.url,
        ));
      }
    }

    // Sort by score descending, then dedupe by title.
    results.sort((a, b) => b.score.compareTo(a.score));
    final seen = <String>{};
    final deduped = results.where((r) {
      final key = r.title.toLowerCase();
      if (seen.contains(key)) return false;
      seen.add(key);
      return true;
    }).take(6).toList(growable: false);

    // Build citations with index.
    var i = startIndex;
    return deduped.map((h) {
      final idx = i++;
      if (h.type == CitationType.wikipedia) {
        return Citation(index: idx, title: h.title, url: h.url, snippet: h.snippet, type: h.type);
      }
      return Citation.fromDoc(idx, h.title, h.snippet);
    }).toList();
  }  // ---------------------------------------------------------------------------
  // SEMANTIC vs STRICT SEARCH — two search modes
  // ---------------------------------------------------------------------------

  /// STRICT search: case-sensitive exact-match on symbol, formula, or full
  /// name. Returns 1–2 hits max. Fast, no network.
  ///
  /// Use case: user types "CuSO4" or "H2O" verbatim and wants exact data.
  Future<List<Citation>> searchStrict(String query, {int startIndex = 1}) async {
    if (!_loaded) await init();
    final results = <_DocHit>[];
    final q = query;  // case-sensitive
    // Elements
    for (final e in _elements) {
      final sym = e['sym'] as String?;
      final name = e['name'] as String?;
      if (sym == q) {
        results.add(_DocHit(
          title: '${name} (${sym}, #${e['num']})',
          snippet: (e['summary'] as String?) ?? '',
          score: 1.0,
          type: CitationType.bundledDoc,
        ));
      } else if (name == q) {
        results.add(_DocHit(
          title: '${name} (${sym}, #${e['num']})',
          snippet: (e['summary'] as String?) ?? '',
          score: 1.0,
          type: CitationType.bundledDoc,
        ));
      }
    }
    // Compounds
    for (final c in _compounds) {
      final formula = c['formula'] as String?;
      final name = c['name'] as String?;
      if (formula == q || name == q) {
        final summary = (c['summary'] as String?) ?? '';
        final uses = (c['uses'] as List?)?.join(', ') ?? '';
        final hazards = (c['hazards'] as List?)?.join(', ') ?? '';
        results.add(_DocHit(
          title: '${name} (${formula})',
          snippet: '$summary Uses: $uses. Hazards: $hazards.',
          score: 1.0,
          type: CitationType.bundledDoc,
        ));
      }
    }
    var i = startIndex;
    return results.take(2).map((h) {
      final idx = i++;
      return Citation.fromDoc(idx, h.title, h.snippet);
    }).toList();
  }

  /// SEMANTIC search: fuzzy matching with synonyms + partial matches +
  /// related compounds + Wikipedia + DuckDuckGo + PubChem fallbacks.
  ///
  /// Use case: user asks "what's that blue stuff in chemistry class?" — the
  /// query "blue stuff" matches CuSO4·5H2O via its `color: blue crystals`
  /// field.
  Future<List<Citation>> searchSemantic(String query, {
    int startIndex = 1,
    int limit = 6,
    bool fetchWiki = true,
    bool fetchPubChem = true,
    bool fetchWeb = true,
  }) async {
    if (!_loaded) await init();
    final results = <_DocHit>[];
    final q = query.toLowerCase().trim();

    // 1. Periodic table — synonym-aware (e.g. "Fe" → iron, "potassium" → K).
    for (final e in _elements) {
      final sym = (e['sym'] as String?)?.toLowerCase() ?? '';
      final name = (e['name'] as String?)?.toLowerCase() ?? '';
      final summary = (e['summary'] as String?)?.toLowerCase() ?? '';
      final appearance = (e['appearance'] as String?)?.toLowerCase() ?? '';
      final category = (e['category'] as String?)?.toLowerCase() ?? '';
      double score = 0;
      if (sym == q) score = 1.0;
      else if (name == q) score = 1.0;
      else if (name.contains(q) || q.contains(name)) score = 0.85;
      else if (q.split(' ').any((word) => name.contains(word) || summary.contains(word))) score = 0.6;
      else if (q.contains(appearance) || appearance.contains(q)) score = 0.5;
      else if (q.contains(category)) score = 0.45;
      else if (sym.isNotEmpty && q.split(' ').any((w) => w == sym)) score = 0.95;
      if (score > 0) {
        results.add(_DocHit(
          title: '${e['name']} (${e['sym']}, #${e['num']})',
          snippet: (e['summary'] as String?) ?? '',
          score: score,
          type: CitationType.bundledDoc,
        ));
      }
    }

    // 2. Common compounds — search by color, state, formula, name, summary keywords.
    for (final c in _compounds) {
      final formula = (c['formula'] as String?)?.toLowerCase() ?? '';
      final name = (c['name'] as String?)?.toLowerCase() ?? '';
      final color = (c['color'] as String?)?.toLowerCase() ?? '';
      final state = (c['state'] as String?)?.toLowerCase() ?? '';
      final summary = (c['summary'] as String?)?.toLowerCase() ?? '';
      final uses = (c['uses'] as List?)?.map((e) => e.toString().toLowerCase()).join(' ') ?? '';
      final hazards = (c['hazards'] as List?)?.map((e) => e.toString().toLowerCase()).join(' ') ?? '';
      double score = 0;
      if (formula.startsWith(q) || formula.contains(q)) score = 0.9;
      else if (name == q) score = 0.95;
      else if (name.contains(q) || q.contains(name)) score = 0.85;
      else if (q.contains(color) || color.contains(q)) score = 0.7;  // "blue stuff" → CuSO4
      else if (q.contains(state)) score = 0.4;
      else if (summary.contains(q) || q.contains(summary.substring(0, summary.length > 60 ? 60 : summary.length))) score = 0.5;
      else if (uses.contains(q) || hazards.contains(q)) score = 0.4;
      else if (q.split(' ').any((word) => name.contains(word) || summary.contains(word) || uses.contains(word))) score = 0.55;
      if (score > 0) {
        final sumStr = (c['summary'] as String?) ?? '';
        final usesStr = (c['uses'] as List?)?.join(', ') ?? '';
        final hazardsStr = (c['hazards'] as List?)?.join(', ') ?? '';
        results.add(_DocHit(
          title: '${c['name']} (${c['formula']})',
          snippet: '$sumStr Uses: $usesStr. Hazards: $hazardsStr.',
          score: score,
          type: CitationType.bundledDoc,
        ));
      }
    }

    // 3. Lab safety pictograms.
    final pictos = (_safety['pictograms'] as List?) ?? const [];
    for (final p in pictos.whereType<Map<String, dynamic>>()) {
      final name = (p['name'] as String?)?.toLowerCase() ?? '';
      final summary = (p['summary'] as String?)?.toLowerCase() ?? '';
      if (name.contains(q) || q.contains(name) || summary.contains(q)) {
        results.add(_DocHit(
          title: 'Hazard: ${p['name']} (${p['id']})',
          snippet: (p['summary'] as String?) ?? '',
          score: 0.6,
          type: CitationType.bundledDoc,
        ));
      }
    }

    // 4. Wikipedia fallback (if no strong in-app hit).
    if (fetchWiki && results.where((r) => r.score > 0.7).isEmpty) {
      final wiki = await WikipediaService.instance.searchWithSummaries(query, limit: 3);
      for (final w in wiki) {
        results.add(_DocHit(
          title: w.title,
          snippet: w.snippet,
          score: 0.7,
          type: CitationType.wikipedia,
          url: w.url,
        ));
      }
    }

    // 5. PubChem lookup — authoritative chemical data.
    if (fetchPubChem && results.where((r) => r.score > 0.85).isEmpty) {
      final pc = await PubChemService.instance.lookupByName(query);
      if (pc != null) {
        results.add(_DocHit(
          title: 'PubChem: ${pc.iupacName ?? pc.molecularFormula} (${pc.molecularFormula})',
          snippet: pc.summary,
          score: 0.95,
          type: CitationType.bundledDoc,
          url: pc.pubchemUrl,
        ));
      }
    }

    // 6. DuckDuckGo web search (broadest coverage).
    if (fetchWeb && results.length < limit) {
      final ws = await WebSearchService.instance.search(query, limit: limit - results.length);
      for (final w in ws) {
        results.add(_DocHit(
          title: w.title.isNotEmpty ? w.title : 'Web result',
          snippet: w.snippet,
          score: 0.5,
          type: CitationType.wikipedia,  // render as wiki-style
          url: w.url,
        ));
      }
    }

    // Sort by score desc, dedupe by title.
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
      final idx = i++;
      if (h.type == CitationType.wikipedia) {
        return Citation(index: idx, title: h.title, url: h.url, snippet: h.snippet, type: h.type);
      }
      return Citation.fromDoc(idx, h.title, h.snippet);
    }).toList();
  }

}



class _DocHit {
  final String title;
  final String snippet;
  final double score;
  final CitationType type;
  final String url;
  const _DocHit({
    required this.title,
    required this.snippet,
    required this.score,
    required this.type,
    this.url = '',
  });
}
