import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// One Wikipedia source — used for both inline [n] citations and the
/// fact-checker's reference database.
class WikiSource {
  final String title;
  final String url;
  final String snippet;      // first ~1-2 sentences (extract)
  final String? thumbnailUrl;
  final int? pageId;
  final double relevance;   // 0..1, used for ranking

  const WikiSource({
    required this.title,
    required this.url,
    required this.snippet,
    this.thumbnailUrl,
    this.pageId,
    this.relevance = 0.0,
  });

  factory WikiSource.fromSearchJson(Map<String, dynamic> j) {
    final title = (j['title'] as String?) ?? '';
    return WikiSource(
      title: title,
      url: (j['url'] as String?) ??
          'https://en.wikipedia.org/wiki/${Uri.encodeComponent(title.replaceAll(' ', '_'))}',
      snippet: _stripHtml((j['snippet'] as String?) ?? ''),
      pageId: j['pageid'] as int?,
      relevance: 0.5,
    );
  }

  factory WikiSource.fromSummaryJson(Map<String, dynamic> j) {
    final t = (j['title'] as String?) ?? '';
    String? thumb;
    if (j['thumbnail'] is Map) {
      thumb = (j['thumbnail'] as Map)['source'] as String?;
    }
    String url;
    if (j['content_urls'] is Map) {
      final cu = j['content_urls'] as Map;
      if (cu['desktop'] is Map) {
        final d = cu['desktop'] as Map;
        url = (d['page'] as String?) ??
            'https://en.wikipedia.org/wiki/${Uri.encodeComponent(t.replaceAll(' ', '_'))}';
      } else {
        url = 'https://en.wikipedia.org/wiki/${Uri.encodeComponent(t.replaceAll(' ', '_'))}';
      }
    } else {
      url = 'https://en.wikipedia.org/wiki/${Uri.encodeComponent(t.replaceAll(' ', '_'))}';
    }
    return WikiSource(
      title: t,
      url: url,
      snippet: (j['extract'] as String?) ?? '',
      thumbnailUrl: thumb,
      pageId: j['pageid'] as int?,
      relevance: 0.7,
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'url': url,
        'snippet': snippet,
        'thumbnailUrl': thumbnailUrl,
        'pageId': pageId,
        'relevance': relevance,
      };

  static String _stripHtml(String s) =>
      s.replaceAll(RegExp(r'<[^>]*>'), '').trim();
}

/// Wikipedia REST API client. Two endpoints:
///   * search(query) — list of relevant articles (title + snippet + URL)
///   * summary(title) — full first-paragraph extract + thumbnail
///
/// Used by:
///   * OpenRouterService.writeScientificContext — pre-fetches sources for the
///     LLM so it can cite [1], [2], etc. in its answer.
///   * FactCheckerService — verifies each claim against Wikipedia.
class WikipediaService {
  WikipediaService._();
  static final WikipediaService instance = WikipediaService._();

  static const String _apiBase = 'https://en.wikipedia.org/w/api.php';
  static const String _restBase = 'https://en.wikipedia.org/api/rest_v1';

  final http.Client _client = http.Client();

  /// Search Wikipedia for [query]. Returns up to [limit] matches.
  /// Each match has a short HTML-stripped snippet — for the full extract,
  /// follow up with [summary].
  Future<List<WikiSource>> search(String query, {int limit = 5}) async {
    if (query.trim().isEmpty) return const [];
    try {
      final uri = Uri.parse(_apiBase).replace(queryParameters: {
        'action': 'query',
        'list': 'search',
        'srsearch': query,
        'srlimit': limit.toString(),
        'format': 'json',
        'origin': '*',
      });
      final res = await _client.get(uri, headers: {
        'User-Agent': 'SpectruLenPor/5.1 (https://spectraglass.app)',
      }).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return const [];
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final query_ = json['query'] as Map<String, dynamic>?;
      final search = query_?['search'] as List?;
      if (search == null) return const [];
      return search
          .whereType<Map<String, dynamic>>()
          .map(WikiSource.fromSearchJson)
          .toList(growable: false);
    } catch (e) {
      debugPrint('[Wikipedia] search failed: $e');
      return const [];
    }
  }

  /// Fetch the first-paragraph extract for [title] (with optional thumbnail).
  Future<WikiSource?> summary(String title) async {
    if (title.trim().isEmpty) return null;
    try {
      final uri = Uri.parse('$_restBase/page/summary/${Uri.encodeComponent(title.replaceAll(' ', '_'))}');
      final res = await _client.get(uri, headers: {
        'User-Agent': 'SpectruLenPor/5.1 (https://spectraglass.app)',
      }).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      return WikiSource.fromSummaryJson(json);
    } catch (e) {
      debugPrint('[Wikipedia] summary failed: $e');
      return null;
    }
  }

  /// Combined search: query Wikipedia, then fetch summaries for the top
  /// [limit] results. Returns the highest-quality sources.
  Future<List<WikiSource>> searchWithSummaries(String query, {int limit = 4}) async {
    final hits = await search(query, limit: limit);
    if (hits.isEmpty) return const [];
    final summaries = <WikiSource>[];
    for (final h in hits.take(limit)) {
      final s = await summary(h.title);
      if (s != null && s.snippet.isNotEmpty) {
        summaries.add(WikiSource(
          title: s.title,
          url: s.url,
          snippet: s.snippet,
          thumbnailUrl: s.thumbnailUrl,
          pageId: s.pageId,
          relevance: h.relevance,
        ));
      } else {
        summaries.add(h);
      }
    }
    return summaries;
  }

  void dispose() {
    _client.close();
  }
}
