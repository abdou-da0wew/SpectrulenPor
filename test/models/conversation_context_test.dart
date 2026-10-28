import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/models/conversation_context.dart';

void main() {
  group('ConversationContext structured schema & <context_update>', () {
    test('parses plain <context_update> block and strips it from visible reply',
        () {
      const raw = '''Copper sulfate is bright blue in pentahydrate form [1].

<context_update>
{"topic": "Copper(II) Sulfate", "user_goal": "understand hydration", "chemicalFormula": "CuSO4·5H2O", "stateOfMatter": "solid", "physicalProperties": "blue triclinic crystals, 2.28 g/cm3", "established_facts": ["CuSO4·5H2O is blue"], "open_questions": ["anhydrous color?"], "referenced_entities": ["CuSO4", "H2O"]}
</context_update>''';

      final (visible, update) = ConversationContext.extractFromResponse(raw);
      expect(visible, 'Copper sulfate is bright blue in pentahydrate form [1].');
      expect(visible.contains('<context_update>'), isFalse);
      expect(update, isNotNull);
      expect(update!.topic, 'Copper(II) Sulfate');
      expect(update.objectIdentified, 'Copper(II) Sulfate');
      expect(update.userGoal, 'understand hydration');
      expect(update.chemicalFormula, 'CuSO4·5H2O');
      expect(update.stateOfMatter, 'solid');
      expect(update.physicalProperties, contains('2.28 g/cm3'));
      expect(update.establishedFacts, ['CuSO4·5H2O is blue']);
      expect(update.openQuestions, ['anhydrous color?']);
      expect(update.referencedEntities, ['CuSO4', 'H2O']);
    });

    test('parses fenced ```json <context_update> block anywhere in response',
        () {
      const raw = '''Here is the explanation.

```json
<context_update>
{"objectIdentified": "Titration", "user_goal": "find endpoint", "pH_at_equivalence": 7.0}
</context_update>
```

Feel free to ask follow-up questions.''';

      final (visible, update) = ConversationContext.extractFromResponse(raw);
      expect(visible.contains('context_update'), isFalse);
      expect(visible.contains('```'), isFalse);
      expect(visible, contains('Here is the explanation.'));
      expect(visible, contains('Feel free to ask follow-up questions.'));
      expect(update, isNotNull);
      expect(update!.topic, 'Titration');
      expect(update.extra['pH_at_equivalence'], 7.0);
    });

    test('stripPartialStreamBlock hides incomplete trailing tag while streaming',
        () {
      const midStream =
          'Water boils at 100 °C at 1 atm.\n```xml\n<context_update>\n{"topic": "Wat';
      final cleaned = ConversationContext.stripPartialStreamBlock(midStream);
      expect(cleaned, 'Water boils at 100 °C at 1 atm.');
    });

    test('merge deduplicates lists, preserves extra keys, and renders system prompt block',
        () {
      const initial = ConversationContext(
        topic: 'Water',
        chemicalFormula: 'H2O',
        commonUses: ['Solvent'],
        establishedFacts: ['Formula is H2O'],
        turnCount: 1,
      );
      const delta = ConversationContext(
        topic: 'Liquid Water',
        stateOfMatter: 'liquid',
        commonUses: ['Solvent', 'Coolant'],
        establishedFacts: ['Formula is H2O', 'Molar mass is 18.015 g/mol'],
        userNotes: ['Measured at 25 °C'],
        extra: {'refractiveIndex': 1.333},
      );
      final merged = initial.merge(delta);
      expect(merged.topic, 'Liquid Water');
      expect(merged.chemicalFormula, 'H2O');
      expect(merged.stateOfMatter, 'liquid');
      expect(merged.turnCount, 2);
      expect(merged.commonUses, ['Solvent', 'Coolant']);
      expect(merged.establishedFacts, hasLength(2));
      expect(merged.userNotes, ['Measured at 25 °C']);
      expect(merged.extra['refractiveIndex'], 1.333);

      final promptEn = merged.toSystemPromptBlock(lang: 'en');
      expect(promptEn, contains('CHEMICAL FORMULA: H2O'));
      expect(promptEn, contains('<context_update>'));

      final promptAr = merged.toSystemPromptBlock(lang: 'ar');
      expect(promptAr, contains('الصيغة الكيميائية: H2O'));
      expect(promptAr, contains('<context_update>'));
    });

    test('AnchorContext renders bilingual system prompt cleanly', () {
      final anchor = AnchorContext(
        selectedLabel: 'Borosilicate Beaker',
        moondreamSummary: 'Clear graduated lab beaker on bench',
        firstLlmContext: 'Borosilicate glass contains SiO2 and B2O3 [1].',
        capturedAt: DateTime.utc(2026, 10, 28),
      );
      expect(anchor.toSystemPrompt(lang: 'en'), contains('Borosilicate Beaker'));
      expect(anchor.toSystemPrompt(lang: 'ar'), contains('Borosilicate Beaker'));
    });
  });
}
