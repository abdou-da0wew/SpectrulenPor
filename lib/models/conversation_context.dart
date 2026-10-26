import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Structured, self-updating conversation context — auto-embedded into every
/// system prompt sent to the LLM (so every chat turn sees the FULL accumulated
/// knowledge, not just chat history).
///
/// The AI can emit `<context_update>{...}</context_update>` blocks in any
/// response. The system parses them and merges them into this object — so
/// the AI itself decides what to add / refine / correct.
///
/// Shape (JSON keys the AI uses for updates):
///   {
///     "objectIdentified": "copper sulfate (CuSO4)",
///     "chemicalFormula": "CuSO4·5H2O",
///     "stateOfMatter": "solid (blue pentahydrate crystals)",
///     "physicalProperties": "density 2.28 g/cm³, mp 110°C, blue color",
///     "chemicalProperties": "soluble in water, weakly acidic in solution",
///     "composition": "Cu²⁺ + SO₄²⁻ + 5H₂O",
///     "formation": "produced by treating copper oxide with sulfuric acid",
///     "commonUses": ["electroplating", "fungicide", "algicide"],
///     "hazards": "toxic if ingested, irritant to skin/eyes",
///     "sceneContext": "bottle of CuSO4 next to a glass beaker",
///     "userNotes": ["user wants to know about crystal structure"],
///     "openQuestions": ["is the sample anhydrous or hydrated?"],
///     "labFindings": "added water → blue color deepened",
///     "safetyProtocols": "wear gloves + goggles",
///     "relatedCompounds": ["Cu2O", "CuO", "CuCl2"]
///   }
///
/// All fields are nullable + the AI can add new keys — unknown keys are
/// preserved in [extra] for round-tripping.
class ConversationContext {
  String? objectIdentified;
  String? chemicalFormula;
  String? stateOfMatter;
  String? physicalProperties;
  String? chemicalProperties;
  String? composition;
  String? formation;
  List<String>? commonUses;
  String? hazards;
  String? sceneContext;
  String? moondreamAnalysis;
  String? firstLlmContext;
  List<String>? userNotes;
  List<String>? openQuestions;
  String? labFindings;
  String? safetyProtocols;
  List<String>? relatedCompounds;

  /// Free-form keys the AI added that aren't in the known schema above.
  /// Round-tripped verbatim.
  final Map<String, dynamic> extra = {};

  DateTime lastUpdated;

  ConversationContext({
    this.objectIdentified,
    this.chemicalFormula,
    this.stateOfMatter,
    this.physicalProperties,
    this.chemicalProperties,
    this.composition,
    this.formation,
    this.commonUses,
    this.hazards,
    this.sceneContext,
    this.moondreamAnalysis,
    this.firstLlmContext,
    this.userNotes,
    this.openQuestions,
    this.labFindings,
    this.safetyProtocols,
    this.relatedCompounds,
    DateTime? lastUpdated,
  }) : lastUpdated = lastUpdated ?? DateTime.now();

  /// Build from a JSON map (the AI's `<context_update>` payload, or a saved
  /// session). Unknown keys go into [extra].
  factory ConversationContext.fromJson(Map<String, dynamic> j) {
    final knownKeys = <String>{
      'objectIdentified', 'chemicalFormula', 'stateOfMatter',
      'physicalProperties', 'chemicalProperties', 'composition',
      'formation', 'commonUses', 'hazards', 'sceneContext',
      'moondreamAnalysis', 'firstLlmContext', 'userNotes',
      'openQuestions', 'labFindings', 'safetyProtocols',
      'relatedCompounds', 'lastUpdated',
    };
    final ctx = ConversationContext(
      objectIdentified: j['objectIdentified'] as String?,
      chemicalFormula: j['chemicalFormula'] as String?,
      stateOfMatter: j['stateOfMatter'] as String?,
      physicalProperties: j['physicalProperties'] as String?,
      chemicalProperties: j['chemicalProperties'] as String?,
      composition: j['composition'] as String?,
      formation: j['formation'] as String?,
      commonUses: (j['commonUses'] as List?)?.map((e) => e.toString()).toList(),
      hazards: j['hazards'] as String?,
      sceneContext: j['sceneContext'] as String?,
      moondreamAnalysis: j['moondreamAnalysis'] as String?,
      firstLlmContext: j['firstLlmContext'] as String?,
      userNotes: (j['userNotes'] as List?)?.map((e) => e.toString()).toList(),
      openQuestions: (j['openQuestions'] as List?)?.map((e) => e.toString()).toList(),
      labFindings: j['labFindings'] as String?,
      safetyProtocols: j['safetyProtocols'] as String?,
      relatedCompounds: (j['relatedCompounds'] as List?)?.map((e) => e.toString()).toList(),
    );
    for (final k in j.keys) {
      if (!knownKeys.contains(k)) ctx.extra[k] = j[k];
    }
    return ctx;
  }

  /// Serialize to JSON for persistence / display.
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      if (objectIdentified != null) 'objectIdentified': objectIdentified,
      if (chemicalFormula != null) 'chemicalFormula': chemicalFormula,
      if (stateOfMatter != null) 'stateOfMatter': stateOfMatter,
      if (physicalProperties != null) 'physicalProperties': physicalProperties,
      if (chemicalProperties != null) 'chemicalProperties': chemicalProperties,
      if (composition != null) 'composition': composition,
      if (formation != null) 'formation': formation,
      if (commonUses != null) 'commonUses': commonUses,
      if (hazards != null) 'hazards': hazards,
      if (sceneContext != null) 'sceneContext': sceneContext,
      if (moondreamAnalysis != null) 'moondreamAnalysis': moondreamAnalysis,
      if (firstLlmContext != null) 'firstLlmContext': firstLlmContext,
      if (userNotes != null) 'userNotes': userNotes,
      if (openQuestions != null) 'openQuestions': openQuestions,
      if (labFindings != null) 'labFindings': labFindings,
      if (safetyProtocols != null) 'safetyProtocols': safetyProtocols,
      if (relatedCompounds != null) 'relatedCompounds': relatedCompounds,
      ...extra,
      'lastUpdated': lastUpdated.toIso8601String(),
    };
    return m;
  }

  /// Merge another context into this one. Non-null fields from [other]
  /// OVERRIDE this one's fields. Lists are appended (deduped). [extra]
  /// keys are merged (other's extras override this one's for matching keys).
  void mergeFrom(ConversationContext other) {
    if (other.objectIdentified != null) objectIdentified = other.objectIdentified;
    if (other.chemicalFormula != null) chemicalFormula = other.chemicalFormula;
    if (other.stateOfMatter != null) stateOfMatter = other.stateOfMatter;
    if (other.physicalProperties != null) physicalProperties = other.physicalProperties;
    if (other.chemicalProperties != null) chemicalProperties = other.chemicalProperties;
    if (other.composition != null) composition = other.composition;
    if (other.formation != null) formation = other.formation;
    if (other.hazards != null) hazards = other.hazards;
    if (other.sceneContext != null) sceneContext = other.sceneContext;
    if (other.moondreamAnalysis != null) moondreamAnalysis = other.moondreamAnalysis;
    if (other.firstLlmContext != null) firstLlmContext = other.firstLlmContext;
    if (other.labFindings != null) labFindings = other.labFindings;
    if (other.safetyProtocols != null) safetyProtocols = other.safetyProtocols;
    if (other.commonUses != null) {
      commonUses = [...?commonUses, ...other.commonUses!].toSet().toList();
    }
    if (other.relatedCompounds != null) {
      relatedCompounds = [...?relatedCompounds, ...other.relatedCompounds!].toSet().toList();
    }
    if (other.userNotes != null) {
      userNotes = [...?userNotes, ...other.userNotes!].toSet().toList();
    }
    if (other.openQuestions != null) {
      // Open questions: replace (the AI can mark them resolved).
      openQuestions = other.openQuestions;
    }
    extra.addAll(other.extra);
    lastUpdated = DateTime.now();
  }

  /// Build the SYSTEM PROMPT BLOCK that gets prepended to every chat call.
  /// Format: structured markdown with the known fields + extras + the
  /// instruction for the AI to emit `<context_update>` blocks.
  String toSystemPromptBlock({String lang = 'en'}) {
    final isAr = lang.startsWith('ar');
    final sb = StringBuffer();
    sb.writeln(isAr
        ? '# السياق المتراكم (يتم تحديثه تلقائياً)'
        : '# Accumulated context (auto-updating)');
    sb.writeln(isAr
        ? 'آخر تحديث: ${lastUpdated.toIso8601String()}'
        : 'Last updated: ${lastUpdated.toIso8601String()}');
    sb.writeln();
    if (objectIdentified != null) sb.writeln('- OBJECT: $objectIdentified');
    if (chemicalFormula != null) sb.writeln('- FORMULA: $chemicalFormula');
    if (stateOfMatter != null) sb.writeln('- STATE: $stateOfMatter');
    if (physicalProperties != null) sb.writeln('- PHYSICAL PROPERTIES: $physicalProperties');
    if (chemicalProperties != null) sb.writeln('- CHEMICAL PROPERTIES: $chemicalProperties');
    if (composition != null) sb.writeln('- COMPOSITION: $composition');
    if (formation != null) sb.writeln('- FORMATION: $formation');
    if (commonUses != null && commonUses!.isNotEmpty) {
      sb.writeln('- COMMON USES: ${commonUses!.join(', ')}');
    }
    if (hazards != null) sb.writeln('- HAZARDS: $hazards');
    if (sceneContext != null) sb.writeln('- SCENE: $sceneContext');
    if (labFindings != null) sb.writeln('- LAB FINDINGS: $labFindings');
    if (safetyProtocols != null) sb.writeln('- SAFETY: $safetyProtocols');
    if (relatedCompounds != null && relatedCompounds!.isNotEmpty) {
      sb.writeln('- RELATED COMPOUNDS: ${relatedCompounds!.join(', ')}');
    }
    if (userNotes != null && userNotes!.isNotEmpty) {
      sb.writeln('- USER NOTES:');
      for (final n in userNotes!) sb.writeln('  - $n');
    }
    if (openQuestions != null && openQuestions!.isNotEmpty) {
      sb.writeln('- OPEN QUESTIONS:');
      for (final q in openQuestions!) sb.writeln('  - $q');
    }
    if (moondreamAnalysis != null) {
      sb.writeln('- MOONDREAM ANALYSIS: $moondreamAnalysis');
    }
    if (firstLlmContext != null) {
      sb.writeln('- FIRST SCIENTIFIC CONTEXT (excerpt): ${_truncate(firstLlmContext!, 400)}');
    }
    if (extra.isNotEmpty) {
      sb.writeln('- ADDITIONAL FIELDS:');
      for (final e in extra.entries) sb.writeln('  - ${e.key}: ${e.value}');
    }
    sb.writeln();
    sb.writeln(isAr
        ? '## تعليمات التحديث التلقائي'
        : '## Auto-update instructions');
    sb.writeln(isAr
        ? 'إذا تعلمت معلومات جديدة أو صححت معلومة موجودة أثناء هذه المحادثة، '
            'يجب عليك إصدار كتلة `<context_update>` في إجابتك بالتنسيق JSON التالي. '
            'سيقوم النظام بدمجها في السياق لجميع الرسائل اللاحقة. '
            'فقط ضع المفاتيح التي تريد تحديثها — لا تكرر المفاتيح التي لم تتغير. '
            'لا تضع الكتلة في تعليق أو داخل نص Markdown آخر — يجب أن تكون نصاً خاماً.'
        : 'If you learn new information OR correct an existing field during this '
            'conversation, you MUST emit a `<context_update>` block in your '
            'response with the JSON shape below. The system will parse it and '
            'merge it into the running context for ALL subsequent messages. '
            'Only include keys you want to update — do not repeat unchanged keys. '
            'Do not wrap the block in a code fence or any other markdown — it must be raw text.');
    sb.writeln('```');
    sb.writeln('<context_update>');
    sb.writeln('  {"objectIdentified": "...", "chemicalFormula": "...", "stateOfMatter": "...", "physicalProperties": "...", "chemicalProperties": "...", "composition": "...", "formation": "...", "commonUses": ["..."], "hazards": "...", "sceneContext": "...", "labFindings": "...", "safetyProtocols": "...", "relatedCompounds": ["..."], "userNotes": ["..."], "openQuestions": ["..."]}');
    sb.writeln('</context_update>');
    sb.writeln('```');
    return sb.toString();
  }

  String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  /// Extract all `<context_update>{...}</context_update>` blocks from a
  /// markdown body. Returns the parsed JSON maps (in order of appearance).
  /// Returns the input with the blocks STRIPPED so the rendered markdown is
  /// clean. Updates the `lastUpdated` timestamp on each merged block.
  static List<ConversationContext> extractUpdatesAndStrip(
      String body, String Function(String) onStripped) {
    final regex = RegExp(
      r'<context_update>\s*(\{[^]*?\})\s*</context_update>',
      multiLine: true,
    );
    final updates = <ConversationContext>[];
    final stripped = body.replaceAllMapped(regex, (m) {
      try {
        final json = jsonDecode(m.group(1)!) as Map<String, dynamic>;
        updates.add(ConversationContext.fromJson(json));
        return '';  // strip from rendered markdown
      } catch (e) {
        debugPrint('[ConversationContext] parse failed: $e');
        return m.group(0)!;  // keep original on parse error
      }
    });
    onStripped(stripped);
    return updates;
  }
}
