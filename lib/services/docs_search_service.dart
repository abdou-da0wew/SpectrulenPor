import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/citation.dart';
import 'wikipedia_service.dart';

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
