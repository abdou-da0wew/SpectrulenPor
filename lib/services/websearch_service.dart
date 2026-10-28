import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'internal_db_service.dart';

/// One DuckDuckGo Instant Answer result — used as a web search citation.
class WebSearchResult {
  final String title;
  final String url;
  final String snippet;
  final String? thumbnailUrl;

  const WebSearchResult({
    required this.title,
    required this.url,
    required this.snippet,
    this.thumbnailUrl,
  });

  factory WebSearchResult.fromJson(Map<String, dynamic> j) => WebSearchResult(
        title: (j['title'] as String?) ?? '',
        url: (j['url'] as String?) ?? '',
        snippet: (j['snippet'] as String?) ?? '',
        thumbnailUrl: j['thumbnailUrl'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'url': url,
        'snippet': snippet,
        'thumbnailUrl': thumbnailUrl,
      };

  factory WebSearchResult.fromAbstract(Map<String, dynamic> j) {
    final url = (j['AbstractURL'] as String?) ?? '';
    final img = j['Image'] as String?;
    return WebSearchResult(
      title: (j['Heading'] as String?) ?? '',
      url: url,
      snippet: (j['Abstract'] as String?) ?? '',
      thumbnailUrl: (img != null && img.isNotEmpty)
          ? (img.startsWith('http') ? img : 'https://duckduckgo.com$img')
          : null,
    );
  }

  factory WebSearchResult.fromRelatedTopic(Map<String, dynamic> j) {
    final link = (j['FirstURL'] as String?) ?? '';
    final icon = (j['Icon'] is Map) ? (j['Icon'] as Map)['URL'] as String? : null;
    final text = (j['Text'] as String?) ?? '';
    final dashIdx = text.indexOf(' - ');
    final derivedTitle = dashIdx > 0
        ? text.substring(0, dashIdx).trim()
        : (link.isNotEmpty
            ? Uri.decodeComponent(link.split('/').last).replaceAll('_', ' ')
            : 'Web reference');
    return WebSearchResult(
      title: derivedTitle,
      url: link,
      snippet: text,
      thumbnailUrl: (icon != null && icon.isNotEmpty)
          ? (icon.startsWith('http') ? icon : 'https://duckduckgo.com$icon')
          : null,
    );
  }
}

/// DuckDuckGo Instant Answer API client with persistent [InternalDatabaseService]
/// response caching.
class WebSearchService {
  WebSearchService._();
  static final WebSearchService instance = WebSearchService._();

  static const String _base = 'https://api.duckduckgo.com';

  final http.Client _client = http.Client();

  /// Search DuckDuckGo for [query]. Returns at most [limit] results.
  Future<List<WebSearchResult>> search(String query, {int limit = 4}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final cacheKey = 'ddg:$limit:$q';
    try {
      final cached = await InternalDatabaseService.instance
          .getCached('websearch', cacheKey);
      if (cached is List) {
        return cached
            .whereType<Map<String, dynamic>>()
            .map(WebSearchResult.fromJson)
            .toList(growable: false);
      }
    } catch (_) {}

    try {
      final uri = Uri.parse(_base).replace(queryParameters: {
        'q': q,
        'format': 'json',
        'no_redirect': '1',
        'no_html': '1',
        'skip_disambig': '1',
      });
      final res = await _client.get(uri, headers: {
        'User-Agent': 'SpectruLenPor/5.4 (https://spectraglass.app)',
      }).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return const [];
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final out = <WebSearchResult>[];

      if ((json['Abstract'] as String?)?.isNotEmpty == true) {
        out.add(WebSearchResult.fromAbstract(json));
      }
      final related = json['RelatedTopics'] as List? ?? const [];
      for (final r in related.whereType<Map<String, dynamic>>()) {
        if (r['Topics'] is List) {
          for (final sub
              in (r['Topics'] as List).whereType<Map<String, dynamic>>()) {
            final parsed = WebSearchResult.fromRelatedTopic(sub);
            if (parsed.snippet.trim().isNotEmpty) out.add(parsed);
            if (out.length >= limit) break;
          }
        } else {
          final parsed = WebSearchResult.fromRelatedTopic(r);
          if (parsed.snippet.trim().isNotEmpty) out.add(parsed);
        }
        if (out.length >= limit) break;
      }

      final seen = <String>{};
      final deduped = out.where((r) {
        if (r.url.isEmpty) return r.snippet.isNotEmpty;
        if (seen.contains(r.url)) return false;
        seen.add(r.url);
        return true;
      }).take(limit).toList(growable: false);

      if (deduped.isNotEmpty) {
        unawaited(InternalDatabaseService.instance.putCache(
          'websearch',
          cacheKey,
          deduped.map((e) => e.toJson()).toList(),
          ttl: const Duration(hours: 24),
        ));
      }
      return deduped;
    } catch (e) {
      debugPrint('[WebSearch] search failed: $e');
      return const [];
    }
  }

  void dispose() => _client.close();
}
