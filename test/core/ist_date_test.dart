import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/utils/ist_date.dart';

void main() {
  test('today() rolls over at IST midnight, not UTC midnight', () {
    // 18:29 UTC = 23:59 IST (same day)
    expect(
      IstDate.today(nowUtc: DateTime.utc(2026, 9, 30, 18, 29)),
      DateTime.utc(2026, 9, 30),
    );
    // 18:30 UTC = 00:00 IST next day (new month)
    expect(
      IstDate.today(nowUtc: DateTime.utc(2026, 9, 30, 18, 30)),
      DateTime.utc(2026, 10, 1),
    );
  });

  test('isFuture blocks dates after today IST only', () {
    final now = DateTime.utc(2026, 9, 30, 12);
    expect(IstDate.isFuture(DateTime(2026, 9, 30), nowUtc: now), isFalse);
    expect(IstDate.isFuture(DateTime(2026, 9, 20), nowUtc: now), isFalse);
    expect(IstDate.isFuture(DateTime(2026, 10, 1), nowUtc: now), isTrue);
  });

  test('toIsoDate pads month and day', () {
    expect(IstDate.toIsoDate(DateTime(2026, 9, 5)), '2026-09-05');
  });

  test('parseDate gives a UTC calendar date comparable with today()', () {
    final d = IstDate.parseDate('2026-10-01');
    expect(d.isUtc, isTrue);
    expect(d, DateTime.utc(2026, 10, 1));
    expect(
      IstDate.parseDate(IstDate.toIsoDate(IstDate.today())),
      IstDate.today(),
    );
  });
}
