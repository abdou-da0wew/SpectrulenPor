import '../models/citation.dart';

/// Candidate source matcher — extracts factual claims from LLM output and
/// compares their tokens with the supplied citation titles and snippets.
///
/// A match is lexical evidence that a source may be relevant. It does NOT
/// verify the claim's meaning, scientific correctness, or whether the source
/// actually entails the claim. The UI deliberately calls this a "source match".
class FactCheckerService {
  FactCheckerService._();
  static final FactCheckerService instance = FactCheckerService._();

  /// Find candidate lexical source matches in [sources] for [llmMarkdown].
  /// Returns a [FactCheckResult] with per-claim verdicts + an annotated
  /// version of the markdown (claims flagged with [SOURCE MATCH n] / [NO SOURCE MATCH]
  /// inline markers).
  Future<FactCheckResult> check({
    required String llmMarkdown,
    required List<Citation> sources,
  }) async {
    final claims = _extractClaims(llmMarkdown);
    if (claims.isEmpty || sources.isEmpty) {
      return FactCheckResult(
        annotatedMarkdown: llmMarkdown,
        verdicts: const [],
        sourceMatchCount: 0,
        noSourceMatchCount: claims.length,
      );
    }
    final verdicts = <ClaimVerdict>[];
    final annotatedBuffer = StringBuffer();
    int cursor = 0;
    for (final claim in claims) {
      // Locate this claim's text in the original markdown.
      final startIdx = llmMarkdown.indexOf(claim.text, cursor);
      if (startIdx < 0) continue;
      annotatedBuffer.write(llmMarkdown.substring(cursor, startIdx));
      final match = _matchClaim(claim.text, sources);
      if (match != null) {
        annotatedBuffer.write(claim.text);
        annotatedBuffer.write(' [SOURCE MATCH ${match.index}]');
        verdicts.add(ClaimVerdict(
          text: claim.text,
          matchScore: match.matchScore,
          citationIndex: match.index,
          status: VerdictStatus.sourceMatched,
        ));
      } else {
        annotatedBuffer.write(claim.text);
        annotatedBuffer.write(' [NO SOURCE MATCH]');
        verdicts.add(ClaimVerdict(
          text: claim.text,
          matchScore: 0.0,
          citationIndex: null,
          status: VerdictStatus.noSourceMatch,
        ));
      }
      cursor = startIdx + claim.text.length;
    }
    annotatedBuffer.write(llmMarkdown.substring(cursor));
    final matched =
        verdicts.where((v) => v.status == VerdictStatus.sourceMatched).length;
    return FactCheckResult(
      annotatedMarkdown: annotatedBuffer.toString(),
      verdicts: verdicts,
      sourceMatchCount: matched,
      noSourceMatchCount: verdicts.length - matched,
    );
  }

  /// Split the LLM markdown into discrete factual claims. Heuristic: each
  /// line/sentence that contains a number, a unit, or a chemical formula is
  /// a candidate claim. Trivial lines (markdown headers, bullets, links)
  /// are skipped.
  List<Claim> _extractClaims(String md) {
    final claims = <Claim>[];
    final lines = md.split(RegExp(r'\n'));
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('#')) continue; // header
      if (trimmed.startsWith('-') || trimmed.startsWith('*')) continue;
      if (trimmed.startsWith('[')) continue; // pure link
      // Split by sentence boundary — including Arabic terminators
      // (؟ question mark, ہ/۔ full stop, … ellipsis) so Arabic claims are
      // segmented as reliably as English ones.
      final sentences = trimmed.split(RegExp(r'(?<=[.!?؟۔…])\s+'));
      for (final s in sentences) {
        final clean = s.trim();
        if (clean.length < 12) continue;
        // A sentence is a "factual claim" if it contains a number, formula,
        // or technical term.
        final isClaim = RegExp(r'\d').hasMatch(clean) ||
            RegExp(r'[A-Z][a-z]?\d').hasMatch(clean) ||
            _hasKeyword(clean);
        if (isClaim) claims.add(Claim(text: clean));
      }
    }
    return claims;
  }

  static final _keywords = <String>{
    'mass',
    'density',
    'temperature',
    'melting',
    'boiling',
    'atomic',
    'molar',
    'formula',
    'compound',
    'element',
    'oxidation',
    'reduction',
    'acid',
    'base',
    'polar',
    'covalent',
    'ionic',
    'solubility',
    'reactive',
    'inert',
    'isotope',
    'valence',
    'ph',
    'solution',
    'concentration',
    'crystal',
    'liquid',
    'gas',
    'solid',
    'metal',
    'nonmetal',
    'halogen',
    'كتلة',
    'كثافة',
    'انصهار',
    'غليان',
    'ذري',
    'مركب',
    'عنصر',
    'حمض',
    'محلول',
  };

  bool _hasKeyword(String s) {
    final l = s.toLowerCase();
    for (final k in _keywords) {
      if (k == 'ph') {
        if (RegExp(r'\bph\b').hasMatch(l)) return true;
      } else if (l.contains(k)) {
        return true;
      }
    }
    return false;
  }

  /// Find a candidate source using lexical token overlap.
  ///
  /// The 0.40 threshold is a retrieval heuristic only, not a verification
  /// threshold. Shared words can occur without the source supporting the claim.
  _SourceMatch? _matchClaim(String claim, List<Citation> sources) {
    _SourceMatch? best;
    final lowerClaim = claim.toLowerCase();
    for (final s in sources) {
      final refText = '${s.title} ${s.snippet}'.toLowerCase();
      final score = _keywordOverlap(lowerClaim, refText);
      if (score > 0.40) {
        if (best == null || score > best.matchScore) {
          best = _SourceMatch(index: s.index, matchScore: score);
        }
      }
    }
    return best;
  }

  /// Token overlap between [claim] and [source] across English, numbers, and Arabic.
  double _keywordOverlap(String claim, String source) {
    final cTokens = _tokenize(claim);
    final sTokens = _tokenize(source);
    if (cTokens.isEmpty || sTokens.isEmpty) return 0;
    final intersection = cTokens.intersection(sTokens);
    return intersection.length / cTokens.length;
  }

  Set<String> _tokenize(String s) {
    return s
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9\u0600-\u06FF.]+'))
        .map((t) => t.replaceAll(RegExp(r'^\.+|\.+$'), ''))
        .where((t) => t.length >= 3 || RegExp(r'\d').hasMatch(t))
        .toSet();
  }
}

/// A single factual claim extracted from the LLM markdown.
class Claim {
  final String text;
  const Claim({required this.text});
}

/// Candidate lexical source match for one extracted claim.
class ClaimVerdict {
  final String text;
  final double matchScore; // 0..1 lexical overlap; not claim confidence
  final int? citationIndex;
  final VerdictStatus status;
  const ClaimVerdict({
    required this.text,
    required this.matchScore,
    required this.citationIndex,
    required this.status,
  });
}

enum VerdictStatus { sourceMatched, noSourceMatch, partial }

/// Candidate source-match results for one LLM message.
class FactCheckResult {
  final String
      annotatedMarkdown; // original markdown + candidate source-match markers
  final List<ClaimVerdict> verdicts;
  final int sourceMatchCount;
  final int noSourceMatchCount;
  const FactCheckResult({
    required this.annotatedMarkdown,
    required this.verdicts,
    required this.sourceMatchCount,
    required this.noSourceMatchCount,
  });

  bool get hasSourceMatches => sourceMatchCount > 0;
}

class _SourceMatch {
  final int index;
  final double matchScore;
  const _SourceMatch({required this.index, required this.matchScore});
}
