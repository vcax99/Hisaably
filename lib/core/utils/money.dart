import 'package:intl/intl.dart';

/// Money is handled as integer paise on the client to avoid floating-point
/// errors. The server stores NUMERIC(14,2); values cross the wire as strings.
abstract final class Money {
  static final _inr = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 2,
  );
  static final _inrWhole = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 0,
  );

  /// Formats paise as INR with Indian digit grouping.
  /// Drops the ".00" for whole-rupee amounts: 2000000 -> "₹20,000".
  static String format(int paise) {
    final negative = paise < 0;
    final abs = paise.abs();
    final text = abs % 100 == 0
        ? _inrWhole.format(abs ~/ 100)
        : _inr.format(abs / 100);
    return negative ? '-$text' : text;
  }

  /// Parses user input such as "850", "850.5", "1,250.75" into paise.
  /// Returns null for invalid input or more than two decimal places.
  /// Parsing is string-based (no doubles) to stay exact.
  static int? parseToPaise(String input) {
    final cleaned = input.replaceAll(',', '').replaceAll('₹', '').trim();
    final match = RegExp(r'^(\d{1,12})(?:\.(\d{1,2}))?$').firstMatch(cleaned);
    if (match == null) return null;
    final rupees = int.parse(match.group(1)!);
    final fraction = (match.group(2) ?? '').padRight(2, '0');
    return rupees * 100 + int.parse(fraction);
  }

  /// Converts paise to the NUMERIC string sent to the server, e.g. "850.50".
  static String toNumericString(int paise) {
    final negative = paise < 0;
    final abs = paise.abs();
    final text = '${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
    return negative ? '-$text' : text;
  }

  /// Parses a NUMERIC value returned by the server ("850.5", "850.50", 850)
  /// into paise without going through double arithmetic for strings.
  static int fromNumeric(Object value) {
    final text = value.toString();
    final negative = text.startsWith('-');
    final parts = (negative ? text.substring(1) : text).split('.');
    final rupees = int.parse(parts[0]);
    final fraction = parts.length > 1
        ? int.parse(parts[1].padRight(2, '0').substring(0, 2))
        : 0;
    final paise = rupees * 100 + fraction;
    return negative ? -paise : paise;
  }

  /// Short Indian-unit label for chart axes: ₹950, ₹1.2K, ₹3.4L, ₹1.1Cr.
  static String compact(int paise) {
    final negative = paise < 0;
    final rupees = paise.abs() / 100;
    String text;
    if (rupees >= 10000000) {
      text = '${_trim(rupees / 10000000)}Cr';
    } else if (rupees >= 100000) {
      text = '${_trim(rupees / 100000)}L';
    } else if (rupees >= 1000) {
      text = '${_trim(rupees / 1000)}K';
    } else {
      text = rupees.round().toString();
    }
    return '${negative ? '-' : ''}₹$text';
  }

  static String _trim(double v) {
    final s = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }
}
