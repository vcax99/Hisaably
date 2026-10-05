import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `SupabaseClient.from()` ignores `postgrestOptions` (no retry opt-out), so
/// offline reads would wait ~7s. Table queries must go through `.rest.from()`.
void main() {
  test('table queries use client.rest.from()', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      // The receiver right before `.from('` (across line breaks).
      for (final m in RegExp(r"(\w+)\s*\.from\('").allMatches(src)) {
        if (m.group(1) != 'rest') {
          final line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
          offenders.add('${f.path}:$line');
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
