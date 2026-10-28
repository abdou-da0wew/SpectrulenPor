import 'dart:convert';

/// Structured, auto-updating scientific & conversational memory embedded into
/// EVERY system prompt sent to the LLM across turns.
///
/// At the end of each turn the LLM emits a `<context_update>{...}</context_update>`
/// JSON delta containing newly discovered facts, refined properties, or resolved
/// questions; [ChatSession] strips the tag from visible Markdown, merges it into
/// the running [ConversationContext], and persists the updated state in
/// `InternalDatabaseService`.
class ConversationContext {
  final String objectIdentified;
  final String userGoal;
  final String chemicalFormula;
  final String stateOfMatter;
  final String physicalProperties;
  final String chemicalProperties;
  final String composition;
  final String formation;
  final List<String> commonUses;
  final String hazards;
  final String sceneContext;
  final String labFindings;
  final String safetyProtocols;
  final List<String> relatedCompounds;
  final List<String> establishedFacts;
  final List<String> openQuestions;
  final List<String> referencedEntities;
  final List<String> userNotes;
  final Map<String, dynamic> extra;
  final int turnCount;
  final DateTime? lastUpdated;

  const ConversationContext({
    String? objectIdentified,
    String? topic,
    this.userGoal = '',
    this.chemicalFormula = '',
    this.stateOfMatter = '',
    this.physicalProperties = '',
    this.chemicalProperties = '',
    this.composition = '',
    this.formation = '',
    this.commonUses = const [],
    this.hazards = '',
    this.sceneContext = '',
    this.labFindings = '',
    this.safetyProtocols = '',
    this.relatedCompounds = const [],
    this.establishedFacts = const [],
    this.openQuestions = const [],
    this.referencedEntities = const [],
    this.userNotes = const [],
    this.extra = const {},
    this.turnCount = 0,
    this.lastUpdated,
  }) : objectIdentified = objectIdentified ?? topic ?? '';

  /// Backward-compatible alias for [objectIdentified].
  String get topic => objectIdentified;

  bool get isEmpty =>
      objectIdentified.isEmpty &&
      userGoal.isEmpty &&
      chemicalFormula.isEmpty &&
      stateOfMatter.isEmpty &&
      physicalProperties.isEmpty &&
      chemicalProperties.isEmpty &&
      composition.isEmpty &&
      formation.isEmpty &&
      commonUses.isEmpty &&
      hazards.isEmpty &&
      sceneContext.isEmpty &&
      labFindings.isEmpty &&
      safetyProtocols.isEmpty &&
      relatedCompounds.isEmpty &&
      establishedFacts.isEmpty &&
      openQuestions.isEmpty &&
      referencedEntities.isEmpty &&
      userNotes.isEmpty &&
      extra.isEmpty;

  static const Set<String> _knownKeys = {
    'objectIdentified',
    'object_identified',
    'topic',
    'userGoal',
    'user_goal',
    'chemicalFormula',
    'chemical_formula',
    'stateOfMatter',
    'state_of_matter',
    'physicalProperties',
    'physical_properties',
    'chemicalProperties',
    'chemical_properties',
    'composition',
    'formation',
    'commonUses',
    'common_uses',
    'hazards',
    'sceneContext',
    'scene_context',
    'labFindings',
    'lab_findings',
    'safetyProtocols',
    'safety_protocols',
    'relatedCompounds',
    'related_compounds',
    'establishedFacts',
    'established_facts',
    'openQuestions',
    'open_questions',
    'referencedEntities',
    'referenced_entities',
    'userNotes',
    'user_notes',
    'extra',
    'turnCount',
    'turn_count',
    'lastUpdated',
    'last_updated',
  };

  factory ConversationContext.fromJson(Map<String, dynamic> j) {
    List<String> strList(dynamic v) {
      if (v is List) {
        return v
            .map((e) => e.toString().trim())
            .where((s) => s.isNotEmpty)
            .toList(growable: false);
      }
      if (v is String && v.trim().isNotEmpty) {
        return [v.trim()];
      }
      return const [];
    }

    String str(String camel, [String? snake, String? alt]) {
      final raw = j[camel] ?? (snake != null ? j[snake] : null) ?? (alt != null ? j[alt] : null);
      return raw?.toString().trim() ?? '';
    }

    final extraMap = <String, dynamic>{};
    if (j['extra'] is Map) {
      (j['extra'] as Map).forEach((k, v) {
        extraMap[k.toString()] = v;
      });
    }
    j.forEach((k, v) {
      if (!_knownKeys.contains(k) && v != null) {
        extraMap[k] = v;
      }
    });

    DateTime? parsedTs;
    final rawTs = j['lastUpdated'] ?? j['last_updated'];
    if (rawTs is String && rawTs.isNotEmpty) {
      parsedTs = DateTime.tryParse(rawTs);
    } else if (rawTs is int) {
      parsedTs = DateTime.fromMillisecondsSinceEpoch(rawTs);
    }

    return ConversationContext(
      objectIdentified: str('objectIdentified', 'object_identified', 'topic'),
      userGoal: str('userGoal', 'user_goal'),
      chemicalFormula: str('chemicalFormula', 'chemical_formula'),
      stateOfMatter: str('stateOfMatter', 'state_of_matter'),
      physicalProperties: str('physicalProperties', 'physical_properties'),
      chemicalProperties: str('chemicalProperties', 'chemical_properties'),
      composition: str('composition'),
      formation: str('formation'),
      commonUses: strList(j['commonUses'] ?? j['common_uses']),
      hazards: str('hazards'),
      sceneContext: str('sceneContext', 'scene_context'),
      labFindings: str('labFindings', 'lab_findings'),
      safetyProtocols: str('safetyProtocols', 'safety_protocols'),
      relatedCompounds: strList(j['relatedCompounds'] ?? j['related_compounds']),
      establishedFacts: strList(j['establishedFacts'] ?? j['established_facts']),
      openQuestions: strList(j['openQuestions'] ?? j['open_questions']),
      referencedEntities:
          strList(j['referencedEntities'] ?? j['referenced_entities']),
      userNotes: strList(j['userNotes'] ?? j['user_notes']),
      extra: extraMap,
      turnCount: ((j['turnCount'] ?? j['turn_count']) as num?)?.toInt() ?? 0,
      lastUpdated: parsedTs,
    );
  }

  Map<String, dynamic> toJson() => {
        'objectIdentified': objectIdentified,
        'topic': objectIdentified,
        'userGoal': userGoal,
        'chemicalFormula': chemicalFormula,
        'stateOfMatter': stateOfMatter,
        'physicalProperties': physicalProperties,
        'chemicalProperties': chemicalProperties,
        'composition': composition,
        'formation': formation,
        'commonUses': commonUses,
        'hazards': hazards,
        'sceneContext': sceneContext,
        'labFindings': labFindings,
        'safetyProtocols': safetyProtocols,
        'relatedCompounds': relatedCompounds,
        'establishedFacts': establishedFacts,
        'openQuestions': openQuestions,
        'referencedEntities': referencedEntities,
        'userNotes': userNotes,
        'extra': extra,
        'turnCount': turnCount,
        'lastUpdated': (lastUpdated ?? DateTime.now()).toIso8601String(),
      };

  static List<String> _dedupMerge(List<String> a, List<String> b,
      {int maxItems = 16}) {
    final seen = <String>{};
    final out = <String>[];
    for (final item in [...a, ...b]) {
      final norm = item.trim();
      if (norm.isEmpty) continue;
      if (seen.add(norm.toLowerCase())) {
        out.add(norm);
      }
    }
    return out.length > maxItems
        ? out.sublist(out.length - maxItems)
        : out;
  }

  static String _pickNonEmpty(String current, String incoming) =>
      incoming.trim().isNotEmpty ? incoming.trim() : current;

  /// Non-destructively merges a `<context_update>` delta into this context.
  ConversationContext merge(ConversationContext delta) {
    final mergedExtra = <String, dynamic>{...extra, ...delta.extra};
    return ConversationContext(
      objectIdentified: _pickNonEmpty(objectIdentified, delta.objectIdentified),
      userGoal: _pickNonEmpty(userGoal, delta.userGoal),
      chemicalFormula: _pickNonEmpty(chemicalFormula, delta.chemicalFormula),
      stateOfMatter: _pickNonEmpty(stateOfMatter, delta.stateOfMatter),
      physicalProperties:
          _pickNonEmpty(physicalProperties, delta.physicalProperties),
      chemicalProperties:
          _pickNonEmpty(chemicalProperties, delta.chemicalProperties),
      composition: _pickNonEmpty(composition, delta.composition),
      formation: _pickNonEmpty(formation, delta.formation),
      commonUses: _dedupMerge(commonUses, delta.commonUses),
      hazards: _pickNonEmpty(hazards, delta.hazards),
      sceneContext: _pickNonEmpty(sceneContext, delta.sceneContext),
      labFindings: _pickNonEmpty(labFindings, delta.labFindings),
      safetyProtocols: _pickNonEmpty(safetyProtocols, delta.safetyProtocols),
      relatedCompounds: _dedupMerge(relatedCompounds, delta.relatedCompounds),
      establishedFacts: _dedupMerge(establishedFacts, delta.establishedFacts),
      openQuestions: delta.openQuestions.isNotEmpty
          ? delta.openQuestions.take(8).toList(growable: false)
          : openQuestions,
      referencedEntities:
          _dedupMerge(referencedEntities, delta.referencedEntities),
      userNotes: _dedupMerge(userNotes, delta.userNotes),
      extra: mergedExtra,
      turnCount: turnCount + 1,
      lastUpdated: DateTime.now(),
    );
  }

  /// Alias matching v5.2 naming.
  ConversationContext mergeFrom(ConversationContext delta) => merge(delta);

  /// Matches `<context_update>...</context_update>` anywhere in the response,
  /// including when the LLM wraps it in ```json / ```xml code fences.
  static final RegExp _blockRegex = RegExp(
    r'(?:```(?:\w+)?\s*)?<context_update>\s*([\s\S]*?)\s*</context_update>(?:\s*```)?',
    multiLine: true,
  );

  /// Matches an in-flight partial `<context_update>...` tail during token streaming.
  static final RegExp _partialTailRegex = RegExp(
    r'(?:```(?:\w+)?\s*)?<context_update>[\s\S]*$',
    multiLine: true,
  );

  /// Extracts all `<context_update>` blocks, merges them in order, and returns
  /// `(cleanedVisibleText, mergedDeltaOrNull)`.
  static (String, ConversationContext?) extractFromResponse(String raw) {
    final matches = _blockRegex.allMatches(raw).toList(growable: false);
    if (matches.isEmpty) {
      return (stripPartialStreamBlock(raw).trim(), null);
    }

    ConversationContext? combined;
    for (final m in matches) {
      final jsonStr = (m.group(1) ?? '').trim();
      if (jsonStr.isEmpty) continue;
      try {
        final decoded = jsonDecode(jsonStr);
        if (decoded is Map<String, dynamic>) {
          final parsed = ConversationContext.fromJson(decoded);
          combined = combined == null ? parsed : combined.merge(parsed);
        }
      } catch (_) {
        // Ignore malformed JSON delta while still stripping the raw block.
      }
    }

    final cleaned =
        stripPartialStreamBlock(raw.replaceAll(_blockRegex, '')).trim();
    return (cleaned, combined);
  }

  /// Hides an incomplete `<context_update>` block while tokens are streaming.
  static String stripPartialStreamBlock(String streamingText) {
    return streamingText
        .replaceAll(_blockRegex, '')
        .replaceAll(_partialTailRegex, '')
        .trimRight();
  }

  /// Renders the full structured running context + mandatory `<context_update>`
  /// instructions for injection into EVERY system prompt sent to the LLM.
  String toSystemPromptBlock({String lang = 'en'}) {
    final b = StringBuffer();
    if (lang.startsWith('ar')) {
      b.writeln('## السياق العلمي التراكمي المثبت (يُحدَّث تلقائياً في كل رسالة)');
      if (!isEmpty) {
        if (objectIdentified.isNotEmpty) b.writeln('- العنصر/الكائن المحدد: $objectIdentified');
        if (userGoal.isNotEmpty) b.writeln('- هدف المستخدم: $userGoal');
        if (chemicalFormula.isNotEmpty) b.writeln('- الصيغة الكيميائية: $chemicalFormula');
        if (stateOfMatter.isNotEmpty) b.writeln('- حالة المادة: $stateOfMatter');
        if (composition.isNotEmpty) b.writeln('- التركيب والمكونات: $composition');
        if (physicalProperties.isNotEmpty) b.writeln('- الخصائص الفيزيائية: $physicalProperties');
        if (chemicalProperties.isNotEmpty) b.writeln('- الخصائص الكيميائية: $chemicalProperties');
        if (formation.isNotEmpty) b.writeln('- التكوين/التحضير: $formation');
        if (commonUses.isNotEmpty) b.writeln('- الاستخدامات: ${commonUses.join('، ')}');
        if (hazards.isNotEmpty) b.writeln('- المخاطر: $hazards');
        if (safetyProtocols.isNotEmpty) b.writeln('- إجراءات السلامة: $safetyProtocols');
        if (sceneContext.isNotEmpty) b.writeln('- سياق المشهد: $sceneContext');
        if (labFindings.isNotEmpty) b.writeln('- ملاحظات التحليل: $labFindings');
        if (relatedCompounds.isNotEmpty) {
          b.writeln('- مركبات ذات صلة: ${relatedCompounds.join('، ')}');
        }
        if (establishedFacts.isNotEmpty) {
          b.writeln('- حقائق علمية مثبتة: ${establishedFacts.join(' ؛ ')}');
        }
        if (openQuestions.isNotEmpty) {
          b.writeln('- أسئلة مفتوحة: ${openQuestions.join(' ؛ ')}');
        }
        if (userNotes.isNotEmpty) {
          b.writeln('- ملاحظات المستخدم: ${userNotes.join(' ؛ ')}');
        }
        extra.forEach((k, v) => b.writeln('- $k: $v'));
      }
      b.writeln();
      b.writeln(
        'في نهاية ردك تماماً (بدون أسوار كود ```)، أضف كتلة تحديث السياق المهيكل بالشكل التالي لتحديث المعرفة العلمية المتراكمة:',
      );
      b.writeln(
        '<context_update>{"objectIdentified":"...","userGoal":"...","chemicalFormula":"...","stateOfMatter":"...","physicalProperties":"...","chemicalProperties":"...","composition":"...","hazards":"...","commonUses":[...],"establishedFacts":[...],"openQuestions":[...],"referencedEntities":[...]}</context_update>',
      );
    } else {
      b.writeln('## Anchored Auto-Updating Scientific Context (Turn #$turnCount)');
      if (!isEmpty) {
        if (objectIdentified.isNotEmpty) b.writeln('- OBJECT IDENTIFIED: $objectIdentified');
        if (userGoal.isNotEmpty) b.writeln('- USER GOAL: $userGoal');
        if (chemicalFormula.isNotEmpty) b.writeln('- CHEMICAL FORMULA: $chemicalFormula');
        if (stateOfMatter.isNotEmpty) b.writeln('- STATE OF MATTER: $stateOfMatter');
        if (composition.isNotEmpty) b.writeln('- COMPOSITION: $composition');
        if (physicalProperties.isNotEmpty) b.writeln('- PHYSICAL PROPERTIES: $physicalProperties');
        if (chemicalProperties.isNotEmpty) b.writeln('- CHEMICAL PROPERTIES: $chemicalProperties');
        if (formation.isNotEmpty) b.writeln('- FORMATION / ORIGIN: $formation');
        if (commonUses.isNotEmpty) b.writeln('- COMMON USES: ${commonUses.join(', ')}');
        if (hazards.isNotEmpty) b.writeln('- HAZARDS: $hazards');
        if (safetyProtocols.isNotEmpty) b.writeln('- SAFETY PROTOCOLS: $safetyProtocols');
        if (sceneContext.isNotEmpty) b.writeln('- SCENE CONTEXT: $sceneContext');
        if (labFindings.isNotEmpty) b.writeln('- LAB FINDINGS: $labFindings');
        if (relatedCompounds.isNotEmpty) {
          b.writeln('- RELATED COMPOUNDS: ${relatedCompounds.join(', ')}');
        }
        if (establishedFacts.isNotEmpty) {
          b.writeln('- ESTABLISHED FACTS: ${establishedFacts.join('; ')}');
        }
        if (openQuestions.isNotEmpty) {
          b.writeln('- OPEN QUESTIONS: ${openQuestions.join('; ')}');
        }
        if (referencedEntities.isNotEmpty) {
          b.writeln('- ENTITIES: ${referencedEntities.join(', ')}');
        }
        if (userNotes.isNotEmpty) {
          b.writeln('- USER NOTES: ${userNotes.join('; ')}');
        }
        extra.forEach((k, v) => b.writeln('- $k: $v'));
      }
      b.writeln();
      b.writeln(
        'At the very end of EVERY reply (plain tag, NO ``` code fences), emit a structured JSON delta inside `<context_update>...</context_update>` updating any newly learned scientific details:',
      );
      b.writeln(
        '<context_update>{"objectIdentified":"...","userGoal":"...","chemicalFormula":"...","stateOfMatter":"...","physicalProperties":"...","chemicalProperties":"...","composition":"...","hazards":"...","commonUses":[...],"relatedCompounds":[...],"establishedFacts":[...],"openQuestions":[...],"referencedEntities":[...]}</context_update>',
      );
    }
    return b.toString().trim();
  }
}

/// Visual & scientific anchor pinned at the start of an analyzed session.
///
/// Embedded into every LLM system prompt alongside the auto-updating
/// [ConversationContext] so the AI always knows the originally captured object,
/// Moondream's structured visual inspection, and the initial scientific overview.
class AnchorContext {
  final String selectedLabel;
  final String moondreamSummary;
  final String firstLlmContext;
  final DateTime capturedAt;

  const AnchorContext({
    required this.selectedLabel,
    required this.moondreamSummary,
    required this.firstLlmContext,
    required this.capturedAt,
  });

  String toSystemPrompt({String lang = 'en'}) {
    final excerpt = firstLlmContext.length > 750
        ? '${firstLlmContext.substring(0, 750)}…'
        : firstLlmContext;
    if (lang.startsWith('ar')) {
      return [
        '## مرساة المشهد البصري (سبكترو لِن بور)',
        '- العنصر المحدد من الكاميرا: $selectedLabel',
        '- وقت الالتقاط: ${capturedAt.toIso8601String()}',
        '- تحليل موندريم البصري المهيكل:\n$moondreamSummary',
        if (excerpt.trim().isNotEmpty)
          '- ملخص السياق العلمي الأولي:\n$excerpt',
        '',
        'أجب بدقة علمية بالاعتماد على المشهد الملتقط والمصادر المرفقة [n]. لا تخترع مراجع.',
      ].join('\n');
    }
    return [
      '## Visual Capture Anchor (SpectruLenPor)',
      '- Selected target object: $selectedLabel',
      '- Captured at: ${capturedAt.toIso8601String()}',
      '- Moondream structured visual inspection:\n$moondreamSummary',
      if (excerpt.trim().isNotEmpty)
        '- Initial grounded scientific report (excerpt):\n$excerpt',
      '',
      'Answer with scientific rigor grounded in the captured object and inline [n] sources. Never invent citations.',
    ].join('\n');
  }
}
