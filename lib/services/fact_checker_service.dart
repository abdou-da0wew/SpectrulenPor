import '../models/citation.dart';

/// Fact-checker — extracts factual claims from LLM output and verifies
/// each against the supplied sources (Wikipedia summaries + bundled docs).
///
/// Output: per-claim confidence score (0..1) + the matched source citation.
/// Claims with no source match are flagged as "unverified" in the UI.
class FactCheckerService {
  FactCheckerService._();
  static final FactCheckerService instance = FactCheckerService._();

  /// Run fact-checking on [llmMarkdown] using [sources] as the reference DB.
  /// Returns a [FactCheckResult] with per-claim verdicts + an annotated
  /// version of the markdown (claims flagged with [VERIFIED n] / [UNVERIFIED]
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
        verifiedCount: 0,
        unverifiedCount: claims.length,
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
        annotatedBuffer.write(' [VERIFIED ${match.index}]');
        verdicts.add(ClaimVerdict(
          text: claim.text,
          confidence: match.confidence,
          citationIndex: match.index,
          status: VerdictStatus.verified,
        ));
      } else {
        annotatedBuffer.write(claim.text);
        annotatedBuffer.write(' [UNVERIFIED]');
        verdicts.add(ClaimVerdict(
          text: claim.text,
          confidence: 0.0,
          citationIndex: null,
          status: VerdictStatus.unverified,
        ));
      }
      cursor = startIdx + claim.text.length;
    }
    annotatedBuffer.write(llmMarkdown.substring(cursor));
    final verified = verdicts.where((v) => v.status == VerdictStatus.verified).length;
    return FactCheckResult(
      annotatedMarkdown: annotatedBuffer.toString(),
      verdicts: verdicts,
      verifiedCount: verified,
      unverifiedCount: verdicts.length - verified,
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
      if (trimmed.startsWith('#')) continue;             // header
      if (trimmed.startsWith('-') || trimmed.startsWith('*')) continue;
      if (trimmed.startsWith('[')) continue;             // pure link
      // Split by sentence boundary
      final sentences = trimmed.split(RegExp(r'(?<=[.!?])\s+'));
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
    'mass', 'density', 'temperature', 'melting', 'boiling', 'atomic',
    'molar', 'formula', 'compound', 'element', 'oxidation', 'reduction',
    'acid', 'base', 'polar', 'covalent', 'ionic', 'solubility', 'reactive',
    'inert', 'isotope', 'valence', 'ph', 'solution', 'concentration',
    'crystal', 'liquid', 'gas', 'solid', 'metal', 'nonmetal', 'halogen',
    'كتلة', 'كثافة', 'انصهار', 'غليان', 'ذري', 'مركب', 'عنصر', 'حمض', 'محلول',
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

  /// Match a claim to the best source — returns null if no source has >40%
  /// keyword overlap with the claim text.
  _SourceMatch? _matchClaim(String claim, List<Citation> sources) {
    _SourceMatch? best;
    final lowerClaim = claim.toLowerCase();
    for (final s in sources) {
      final refText = '${s.title} ${s.snippet}'.toLowerCase();
      final score = _keywordOverlap(lowerClaim, refText);
      if (score > 0.40) {
        if (best == null || score > best.confidence) {
          best = _SourceMatch(index: s.index, confidence: score);
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

/// Verdict for one claim — verified/unverified + matched citation index.
class ClaimVerdict {
  final String text;
  final double confidence;       // 0..1, keyword overlap
  final int? citationIndex;
  final VerdictStatus status;
  const ClaimVerdict({
    required this.text,
    required this.confidence,
    required this.citationIndex,
    required this.status,
  });
}

enum VerdictStatus { verified, unverified, partial }

/// Result of fact-checking one LLM message.
class FactCheckResult {
  final String annotatedMarkdown;   // original markdown + [VERIFIED n] / [UNVERIFIED] inline
  final List<ClaimVerdict> verdicts;
  final int verifiedCount;
  final int unverifiedCount;
  const FactCheckResult({
    required this.annotatedMarkdown,
    required this.verdicts,
    required this.verifiedCount,
    required this.unverifiedCount,
  });

  bool get allVerified => unverifiedCount == 0 && verifiedCount > 0;
}

class _SourceMatch {
  final int index;
  final double confidence;
  const _SourceMatch({required this.index, required this.confidence});
}
