import '../services/wikipedia_service.dart' show WikiSource;

/// One citation source — Wikipedia, bundled docs, or in-app scientific context.
/// Used by the markdown renderer to show [n] inline + the Sources block at
/// the bottom of each assistant message.
class Citation {
  final int index;             // [1], [2], ...
  final String title;
  final String url;            // empty for in-app docs
  final String snippet;        // short extract
  final CitationType type;

  const Citation({
    required this.index,
    required this.title,
    required this.url,
    required this.snippet,
    required this.type,
  });

  Map<String, dynamic> toJson() => {
        'index': index,
        'title': title,
        'url': url,
        'snippet': snippet,
        'type': type.name,
      };

  factory Citation.fromWiki(int i, WikiSource w) => Citation(
        index: i,
        title: w.title,
        url: w.url,
        snippet: w.snippet,
        type: CitationType.wikipedia,
      );

  factory Citation.fromDoc(int i, String title, String snippet) => Citation(
        index: i,
        title: title,
        url: '',
        snippet: snippet,
        type: CitationType.bundledDoc,
      );
}

enum CitationType { wikipedia, bundledDoc, factCheck, moondream }

/// An LLM message annotated with citations + fact-check results.
class AnnotatedMessage {
  final String body;             // markdown text with [n] inline citations
  final List<Citation> citations;

  const AnnotatedMessage({required this.body, this.citations = const []});

  Map<String, dynamic> toJson() => {
        'body': body,
        'citations': citations.map((c) => c.toJson()).toList(),
      };
}
