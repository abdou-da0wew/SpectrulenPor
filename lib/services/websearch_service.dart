import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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

  factory WebSearchResult.fromAbstract(Map<String, dynamic> j) {
    final url = (j['AbstractURL'] as String?) ?? '';
    return WebSearchResult(
      title: (j['Heading'] as String?) ?? '',
      url: url,
      snippet: (j['Abstract'] as String?) ?? '',
      thumbnailUrl: (j['Image'] as String?) != null
          ? 'https://duckduckgo.com${j['Image']}'
          : null,
    );
  }

  factory WebSearchResult.fromRelatedTopic(Map<String, dynamic> j) {
    if (j['Text'] is String) {
      return WebSearchResult(
        title: '',
        url: '',
        snippet: j['Text'] as String,
      );
    }
    final link = j['FirstURL'] as String?;
    final icon = (j['Icon'] as Map?)?['URL'] as String?;
    final text = (j['Text'] as String?) ?? '';
    return WebSearchResult(
      title: text.split(' - ').first,
      url: link ?? '',
      snippet: text,
      thumbnailUrl: icon != null ? 'https://duckduckgo.com$icon' : null,
    );
  }
}

/// DuckDuckGo Instant Answer API client. Returns an authoritative summary
/// (Wikipedia abstract) + related topics + a clickable URL — used as the
/// "web search" component of the citation pipeline.
///
/// Note: DuckDuckGo's IA API is NOT a full web search — it returns a single
/// authoritative instant answer + ~10 related links. For more thorough
/// results, the LLM still has Wikipedia + PubChem + bundled docs.
class WebSearchService {
  WebSearchService._();
  static final WebSearchService instance = WebSearchService._();

  static const String _base = 'https://api.duckduckgo.com';

  final http.Client _client = http.Client();

  /// Search DuckDuckGo for [query]. Returns at most [limit] results.
  Future<List<WebSearchResult>> search(String query, {int limit = 4}) async {
    if (query.trim().isEmpty) return const [];
    try {
      final uri = Uri.parse(_base).replace(queryParameters: {
        'q': query,
        'format': 'json',
        'no_redirect': '1',
        'no_html': '1',
        'skip_disambig': '1',
      });
      final res = await _client.get(uri, headers: {
        'User-Agent': 'SpectruLenPor/5.3 (https://spectraglass.app)',
      }).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return const [];
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final out = <WebSearchResult>[];

      // The abstract is the canonical instant-answer text (Wikipedia excerpt).
      if ((json['Abstract'] as String?)?.isNotEmpty == true) {
        out.add(WebSearchResult.fromAbstract(json));
      }
      // Related topics — 10+ sub-results.
      final related = json['RelatedTopics'] as List? ?? const [];
      for (final r in related.whereType<Map<String, dynamic>>()) {
        // Some related items are nested (Topics list inside a related item).
        if (r['Topics'] is List) {
          for (final sub in (r['Topics'] as List).whereType<Map<String, dynamic>>()) {
            out.add(WebSearchResult.fromRelatedTopic(sub));
            if (out.length >= limit) break;
          }
        } else {
          out.add(WebSearchResult.fromRelatedTopic(r));
        }
        if (out.length >= limit) break;
      }
      // Dedup by URL.
      final seen = <String>{};
      return out.where((r) {
        if (r.url.isEmpty) return true;
        if (seen.contains(r.url)) return false;
        seen.add(r.url);
        return true;
      }).take(limit).toList(growable: false);
    } catch (e) {
      debugPrint('[WebSearch] search failed: $e');
      return const [];
    }
  }

  void dispose() => _client.close();
}
