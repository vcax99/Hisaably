import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/utils/money.dart';

void main() {
  group('Money.parseToPaise', () {
    test('parses whole and fractional rupees exactly', () {
      expect(Money.parseToPaise('850'), 85000);
      expect(Money.parseToPaise('850.5'), 85050);
      expect(Money.parseToPaise('850.05'), 85005);
      expect(Money.parseToPaise('1,250.75'), 125075);
      expect(Money.parseToPaise('₹20,000'), 2000000);
      expect(Money.parseToPaise('0.10'), 10);
    });

    test('rejects invalid input', () {
      for (final input in ['', 'abc', '-5', '1.234', '1.', '.5', '1e5']) {
        expect(Money.parseToPaise(input), isNull, reason: input);
      }
    });
  });

  group('Money.format', () {
    test('uses INR with Indian grouping', () {
      expect(Money.format(85000), '₹850');
      expect(Money.format(2000000), '₹20,000');
      expect(Money.format(1850000), '₹18,500');
      expect(Money.format(1234567890), '₹1,23,45,678.90');
      expect(Money.format(-1500000), '-₹15,000');
    });
  });

  group('Money numeric round-trip', () {
    test('toNumericString / fromNumeric are inverse', () {
      for (final paise in [0, 5, 85050, 2000000, -1500000, 99999999999999]) {
        expect(Money.fromNumeric(Money.toNumericString(paise)), paise);
      }
    });

    test('fromNumeric accepts server shapes', () {
      expect(Money.fromNumeric('850.5'), 85050);
      expect(Money.fromNumeric('850'), 85000);
      expect(Money.fromNumeric(850), 85000);
    });
  });

  test('compact uses Indian units', () {
    expect(Money.compact(95000), '₹950');
    expect(Money.compact(120000), '₹1.2K');
    expect(Money.compact(2000000), '₹20K');
    expect(Money.compact(34000000), '₹3.4L');
    expect(Money.compact(110000000), '₹11L');
    expect(Money.compact(1100000000), '₹1.1Cr');
    expect(Money.compact(-150000), '-₹1.5K');
    expect(Money.compact(0), '₹0');
  });
}
