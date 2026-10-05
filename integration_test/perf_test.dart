// Phase 13: frame-time profiling on a device (profile mode) against the dev
// backend. Run with scripts/run_perf.sh <device-id>, which seeds a temporary
// "Perf" group with 1,000 entries for qa_member and removes it afterwards.
// Timeline summaries land in build/perf/. Measured WITH the ambient motion
// (background waves, logo float) running, so no pumpAndSettle here.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/widgets/wave_background.dart';
import 'package:hisaably/features/auth/domain/username.dart';
import 'package:hisaably/main.dart' as app;
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _memberPassword = String.fromEnvironment('QA_MEMBER_PASSWORD');

/// A/B switch: --dart-define=PERF_MOTION=false measures without the
/// ambient motion (waves, logo float).
const _motion = bool.fromEnvironment('PERF_MOTION', defaultValue: true);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (finder.evaluate().isNotEmpty) return;
    }
    throw TestFailure('Timed out waiting for $finder');
  }

  Finder nav(String label) => find.byKey(ValueKey('nav-$label'));

  testWidgets('scrolling performance', (tester) async {
    ambientMotionEnabled = _motion;
    await app.main();
    await waitFor(
      tester,
      find.byWidgetPredicate(
        (w) =>
            w.key == const ValueKey('nav-Dashboard') ||
            (w is FilledButton &&
                w.child is Text &&
                (w.child! as Text).data == 'Sign in'),
      ),
    );
    if (nav('Dashboard').evaluate().isEmpty) {
      // Sign-in UI isn't what's measured (it's covered by app_flows_test);
      // the app's session listener routes to the shell.
      await Supabase.instance.client.auth.signInWithPassword(
        email: Username.toAuthEmail('qa_member'),
        password: _memberPassword,
      );
      await waitFor(tester, nav('Dashboard'));
    }

    // Dashboard (charts) scroll.
    await waitFor(tester, find.textContaining('balance'));
    await tester.pump(const Duration(milliseconds: 900));
    final dashList = find.byType(Scrollable).first;
    await binding.traceAction(() async {
      for (var i = 0; i < 3; i++) {
        await tester.fling(dashList, const Offset(0, -600), 2000);
        await tester.pump(const Duration(milliseconds: 900));
        await tester.fling(dashList, const Offset(0, 600), 2000);
        await tester.pump(const Duration(milliseconds: 900));
      }
    }, reportKey: 'dashboard_scroll');

    // Expenses, All time: 1,000 rows, paged as you scroll.
    await tester.tap(nav('Expenses'));
    await waitFor(tester, find.text('Filters'));
    await tester.tap(find.text(DateFormatHelper.currentMonthLabel()));
    await tester.pump(const Duration(milliseconds: 900));
    await waitFor(tester, find.text('All time'));
    final list = find.byType(Scrollable).first;
    await binding.traceAction(() async {
      for (var i = 0; i < 25; i++) {
        await tester.fling(list, const Offset(0, -800), 3000);
        await tester.pump(const Duration(milliseconds: 900));
      }
    }, reportKey: 'expenses_scroll');
  });
}

/// "October 2026"-style label of the current month (the list's default).
class DateFormatHelper {
  static String currentMonthLabel() {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final now = DateTime.now().toUtc().add(
      const Duration(hours: 5, minutes: 30),
    );
    return '${months[now.month - 1]} ${now.year}';
  }
}
