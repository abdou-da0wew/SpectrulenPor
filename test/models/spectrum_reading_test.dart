import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/models/spectrum_reading.dart';

void main() {
  group('SpectrumReading.tryParse', () {
    test('parses the firmware telemetry packet', () {
      final r = SpectrumReading.tryParse(r'$UV:1234;IR:567');
      expect(r, isNotNull);
      expect(r!.uvRaw, 1234);
      expect(r.irRaw, 567);
    });

    test('parses with whitespace and CR', () {
      final r = SpectrumReading.tryParse('\$UV:0;IR:4095\r\n');
      expect(r, isNotNull);
      expect(r!.uvRaw, 0);
      expect(r.irRaw, 4095);
    });

    test('rejects non-telemetry lines', () {
      expect(SpectrumReading.tryParse('hello world'), isNull);
      expect(SpectrumReading.tryParse(r'$UV:12'), isNull); // missing IR
      expect(SpectrumReading.tryParse(r'$IR:5;UV:6'), isNotNull);
      expect(SpectrumReading.tryParse(''), isNull);
    });

    test('percent math is normalized to 0..100', () {
      final r = SpectrumReading.tryParse(r'$UV:4095;IR:0')!;
      expect(r.uvPercent, closeTo(100, 0.001));
      expect(r.irPercent, 0);
    });
  });

  group('hazard thresholds', () {
    test('UV hazard at >= 72% full scale', () {
      // 72% of 4095 ~= 2948
      expect(SpectrumReading.tryParse(r'$UV:2949;IR:0')!.uvHazard, isTrue);
      expect(SpectrumReading.tryParse(r'$UV:2947;IR:0')!.uvHazard, isFalse);
    });

    test('IR hazard at >= 80% full scale', () {
      // 80% of 4095 = 3276
      expect(SpectrumReading.tryParse(r'$UV:0;IR:3276')!.irHazard, isTrue);
      expect(SpectrumReading.tryParse(r'$UV:0;IR:3275')!.irHazard, isFalse);
    });

    test('anyHazard is an OR of both channels', () {
      expect(SpectrumReading.tryParse(r'$UV:4000;IR:0')!.anyHazard, isTrue);
      expect(SpectrumReading.tryParse(r'$UV:0;IR:4000')!.anyHazard, isTrue);
      expect(SpectrumReading.tryParse(r'$UV:10;IR:10')!.anyHazard, isFalse);
    });
  });

  group('telemetryLine', () {
    test('English line carries both percentages', () {
      final r = SpectrumReading.tryParse(r'$UV:2048;IR:1024')!;
      final line = r.telemetryLine('en');
      expect(line, contains('UV at 50%'));
      expect(line, contains('IR at 25%'));
    });

    test('Arabic line is Arabic', () {
      final r = SpectrumReading.tryParse(r'$UV:2048;IR:1024')!;
      expect(r.telemetryLine('ar'), contains('المستشعرات'));
    });
  });

  group('matterStateFromText', () {
    test('detects all three states in English', () {
      expect(matterStateFromText('The sample is a clear LIQUID.'),
          MatterState.liquid);
      expect(matterStateFromText('a gas is escaping'), MatterState.gas);
      expect(matterStateFromText('SOLID white powder'), MatterState.solid);
    });

    test('detects states in Arabic', () {
      expect(matterStateFromText('المادة سائلة'), MatterState.liquid);
      expect(matterStateFromText('غاز'), MatterState.gas);
      expect(matterStateFromText('صلب'), MatterState.solid);
    });

    test('unknown when nothing matches', () {
      expect(matterStateFromText('nothing relevant here'),
          MatterState.unknown);
    });
  });

  group('textSignalsHazard', () {
    test('English hazard keywords', () {
      expect(textSignalsHazard('Warning: toxic fumes'), isTrue);
      expect(textSignalsHazard('highly flammable'), isTrue);
      expect(textSignalsHazard('benign water'), isFalse);
      expect(
        textSignalsHazard('Pure water is non-toxic, non-flammable, and poses no hazard.'),
        isFalse,
      );
    });

    test('Arabic hazard keywords', () {
      expect(textSignalsHazard('تحذير: مادة سامة'), isTrue);
      expect(textSignalsHazard('قابل للاشتعال'), isTrue);
      expect(textSignalsHazard('ماء نقي'), isFalse);
      expect(
        textSignalsHazard('كلوريد الصوديوم غير سام وغير قابل للاشتعال ولا يوجد خطر.'),
        isFalse,
      );
    });
  });
}
