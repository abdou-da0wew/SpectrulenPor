import '../services/wikipedia_service.dart' show WikiSource;

/// One citation source — Wikipedia, PubChem, web search, bundled docs, or
/// in-app scientific context. Used by the markdown renderer to show [n]
/// inline + the Sources block at the bottom of each assistant message.
class Citation {
  final int index; // [1], [2], ...
  final String title;
  final String url; // empty for offline bundled docs
  final String snippet; // short extract
  final CitationType type;
  final String? thumbnailUrl; // optional inline thumbnail (from docs search hits)

  const Citation({
    required this.index,
    required this.title,
    required this.url,
    required this.snippet,
    required this.type,
    this.thumbnailUrl,
  });

  Map<String, dynamic> toJson() => {
        'index': index,
        'title': title,
        'url': url,
        'snippet': snippet,
        'type': type.name,
        if (thumbnailUrl != null) 'thumbnailUrl': thumbnailUrl,
      };

  factory Citation.fromWiki(int i, WikiSource w) => Citation(
        index: i,
        title: w.title,
        url: w.url,
        snippet: w.snippet,
        type: CitationType.wikipedia,
      );

  factory Citation.fromDoc(
    int i,
    String title,
    String snippet, {
    String url = '',
    CitationType type = CitationType.bundledDoc,
    String? thumbnailUrl,
  }) =>
      Citation(
        index: i,
        title: title,
        url: url,
        snippet: snippet,
        type: type,
        thumbnailUrl: thumbnailUrl,
      );
}

enum CitationType { wikipedia, bundledDoc, pubchem, web, factCheck, moondream }

/// An LLM message annotated with citations + fact-check results.
class AnnotatedMessage {
  final String body; // markdown text with [n] inline citations
  final List<Citation> citations;
  final int verifiedCount;
  final int unverifiedCount;

  const AnnotatedMessage({
    required this.body,
    this.citations = const [],
    this.verifiedCount = 0,
    this.unverifiedCount = 0,
  });

  Map<String, dynamic> toJson() => {
        'body': body,
        'citations': citations.map((c) => c.toJson()).toList(),
        'verifiedCount': verifiedCount,
        'unverifiedCount': unverifiedCount,
      };
}
