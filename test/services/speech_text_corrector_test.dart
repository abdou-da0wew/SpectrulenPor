import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/services/speech_text_corrector.dart';

void main() {
  group('SpeechTextCorrector', () {
    test('removes Arabic diacritics and normalizes punctuation', () {
      expect(
        SpeechTextCorrector.correct(
          'أَنا  أُحبّ التَّجربة ؟',
          languageCode: 'ar-EG',
          isFinal: true,
        ),
        'أنا أحب التجربة؟',
      );
    });

    test('preserves Arabic words whose meaning changes with spelling', () {
      expect(
        SpeechTextCorrector.correct(
          'على الطريق',
          languageCode: 'ar-EG',
          isFinal: true,
        ),
        'على الطريق.',
      );
    });

    test('normalizes known Arabic project-name transcription variants', () {
      expect(
        SpeechTextCorrector.correct(
          'سبكترولين بور يعمل الآن',
          languageCode: 'ar-EG',
          isFinal: true,
        ),
        'SpectruLenPor يعمل الآن.',
      );
    });

    test('corrects known English technology terms', () {
      expect(
        SpeechTextCorrector.correct(
          'spectrulen poor uses open router and super tonic 3 on esp 32',
          languageCode: 'en-US',
          isFinal: true,
        ),
        'SpectruLenPor uses OpenRouter and Supertonic-3 on ESP32.',
      );
    });

    test('normalizes common speech punctuation and first-letter casing', () {
      expect(
        SpeechTextCorrector.correct(
          'this  is a test ,and i like it',
          languageCode: 'en-US',
          isFinal: true,
        ),
        'This is a test, and I like it.',
      );
    });

    test('does not rewrite unfamiliar words', () {
      expect(
        SpeechTextCorrector.correct(
          'this unfamiliar expression stays here',
          languageCode: 'en-US',
          isFinal: true,
        ),
        'This unfamiliar expression stays here.',
      );
    });

    test('does not append sentence punctuation to partial results', () {
      expect(
        SpeechTextCorrector.correct(
          'this is still being recognized',
          languageCode: 'en-US',
        ),
        'This is still being recognized',
      );
    });

    test('keeps empty recognition empty', () {
      expect(
        SpeechTextCorrector.correct('', languageCode: 'en-US', isFinal: true),
        isEmpty,
      );
    });
  });
}
