/// Date helpers pinned to India Standard Time (UTC+05:30, no DST).
///
/// Business rules ("no future dates", month boundaries) use IST regardless of
/// the device's timezone, matching the server's Asia/Kolkata evaluation.
abstract final class IstDate {
  static const _offset = Duration(hours: 5, minutes: 30);

  /// Current calendar date in IST, as a date-only value (UTC midnight).
  static DateTime today({DateTime? nowUtc}) {
    final ist = (nowUtc ?? DateTime.now().toUtc()).add(_offset);
    return DateTime.utc(ist.year, ist.month, ist.day);
  }

  static DateTime dateOnly(DateTime d) => DateTime.utc(d.year, d.month, d.day);

  /// True if [date] is after today's IST date.
  static bool isFuture(DateTime date, {DateTime? nowUtc}) =>
      dateOnly(date).isAfter(today(nowUtc: nowUtc));

  /// ISO date string (YYYY-MM-DD) for a Postgres DATE column.
  static String toIsoDate(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }
}
