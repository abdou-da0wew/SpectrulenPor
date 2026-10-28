import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'internal_db_service.dart';

/// One Wikipedia source — used for both inline [n] citations and the
/// fact-checker's reference database.
class WikiSource {
  final String title;
  final String url;
  final String snippet; // first ~1-2 sentences (extract)
  final String? thumbnailUrl;
  final int? pageId;
  final double relevance; // 0..1, used for ranking

  const WikiSource({
    required this.title,
    required this.url,
    required this.snippet,
    this.thumbnailUrl,
    this.pageId,
    this.relevance = 0.0,
  });

  factory WikiSource.fromJson(Map<String, dynamic> j) => WikiSource(
        title: (j['title'] as String?) ?? '',
        url: (j['url'] as String?) ?? '',
        snippet: (j['snippet'] as String?) ?? '',
        thumbnailUrl: j['thumbnailUrl'] as String?,
        pageId: (j['pageId'] as num?)?.toInt(),
        relevance: (j['relevance'] as num?)?.toDouble() ?? 0.5,
      );

  factory WikiSource.fromSearchJson(Map<String, dynamic> j,
      {String langHost = 'en'}) {
    final title = (j['title'] as String?) ?? '';
    return WikiSource(
      title: title,
      url: (j['url'] as String?) ??
          'https://$langHost.wikipedia.org/wiki/${Uri.encodeComponent(title.replaceAll(' ', '_'))}',
      snippet: _stripHtml((j['snippet'] as String?) ?? ''),
      pageId: (j['pageid'] as num?)?.toInt(),
      relevance: 0.5,
    );
  }

  factory WikiSource.fromSummaryJson(Map<String, dynamic> j,
      {String langHost = 'en'}) {
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
            'https://$langHost.wikipedia.org/wiki/${Uri.encodeComponent(t.replaceAll(' ', '_'))}';
      } else {
        url =
            'https://$langHost.wikipedia.org/wiki/${Uri.encodeComponent(t.replaceAll(' ', '_'))}';
      }
    } else {
      url =
          'https://$langHost.wikipedia.org/wiki/${Uri.encodeComponent(t.replaceAll(' ', '_'))}';
    }
    return WikiSource(
      title: t,
      url: url,
      snippet: (j['extract'] as String?) ?? '',
      thumbnailUrl: thumb,
      pageId: (j['pageid'] as num?)?.toInt(),
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

/// Wikipedia REST API client with persistent [InternalDatabaseService] caching.
class WikipediaService {
  WikipediaService._();
  static final WikipediaService instance = WikipediaService._();

  final http.Client _client = http.Client();

  String _resolveHost(String text, String? lang) {
    if (lang != null && lang.startsWith('ar')) return 'ar';
    if (RegExp(r'[\u0600-\u06FF]').hasMatch(text)) return 'ar';
    return 'en';
  }

  /// Search Wikipedia for [query]. Returns up to [limit] matches.
  Future<List<WikiSource>> search(
    String query, {
    int limit = 5,
    String? lang,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final host = _resolveHost(q, lang);
    try {
      final uri =
          Uri.parse('https://$host.wikipedia.org/w/api.php').replace(
        queryParameters: {
          'action': 'query',
          'list': 'search',
          'srsearch': q,
          'srlimit': limit.toString(),
          'format': 'json',
          'origin': '*',
        },
      );
      final res = await _client.get(uri, headers: {
        'User-Agent': 'SpectruLenPor/5.4 (https://spectraglass.app)',
      }).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return const [];
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final queryMap = json['query'] as Map<String, dynamic>?;
      final searchList = queryMap?['search'] as List?;
      if (searchList == null) return const [];
      return searchList
          .whereType<Map<String, dynamic>>()
          .map((m) => WikiSource.fromSearchJson(m, langHost: host))
          .toList(growable: false);
    } catch (e) {
      debugPrint('[Wikipedia] search failed: $e');
      return const [];
    }
  }

  /// Fetch the first-paragraph extract for [title] (with persistent DB cache).
  Future<WikiSource?> summary(String title, {String? lang}) async {
    final t = title.trim();
    if (t.isEmpty) return null;
    final host = _resolveHost(t, lang);
    final cacheKey = 'summary:$host:$t';
    try {
      final cached =
          await InternalDatabaseService.instance.getCached('wiki', cacheKey);
      if (cached is Map<String, dynamic>) {
        return WikiSource.fromJson(cached);
      }
    } catch (_) {}

    try {
      final uri = Uri.parse(
        'https://$host.wikipedia.org/api/rest_v1/page/summary/${Uri.encodeComponent(t.replaceAll(' ', '_'))}',
      );
      final res = await _client.get(uri, headers: {
        'User-Agent': 'SpectruLenPor/5.4 (https://spectraglass.app)',
      }).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final out = WikiSource.fromSummaryJson(json, langHost: host);
      unawaited(InternalDatabaseService.instance.putCache(
        'wiki',
        cacheKey,
        out.toJson(),
        ttl: const Duration(hours: 72),
      ));
      return out;
    } catch (e) {
      debugPrint('[Wikipedia] summary failed: $e');
      return null;
    }
  }

  /// Combined search + summary fetch with persistent DB response caching.
  Future<List<WikiSource>> searchWithSummaries(
    String query, {
    int limit = 4,
    String? lang,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final host = _resolveHost(q, lang);
    final cacheKey = 'search_sum:$host:$limit:$q';

    try {
      final cached =
          await InternalDatabaseService.instance.getCached('wiki', cacheKey);
      if (cached is List) {
        return cached
            .whereType<Map<String, dynamic>>()
            .map(WikiSource.fromJson)
            .toList(growable: false);
      }
    } catch (_) {}

    final hits = await search(q, limit: limit, lang: lang);
    if (hits.isEmpty) return const [];
    final summaries = <WikiSource>[];
    for (final h in hits.take(limit)) {
      final s = await summary(h.title, lang: host);
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
    if (summaries.isNotEmpty) {
      unawaited(InternalDatabaseService.instance.putCache(
        'wiki',
        cacheKey,
        summaries.map((e) => e.toJson()).toList(),
        ttl: const Duration(hours: 48),
      ));
    }
    return summaries;
  }

  void dispose() {
    _client.close();
  }
}
