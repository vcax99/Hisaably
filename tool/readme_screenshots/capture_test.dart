// Captures README screenshots on the iOS simulator against the dev backend's
// fictional "Flat 4B" demo group (Group Admin aarav, member meera).
// Run with scripts/capture_readme_screens.sh (passwords come in as
// --dart-define values and are never stored).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hisaably/core/widgets/wave_background.dart';
import 'package:hisaably/main.dart' as app;
import 'package:integration_test/integration_test.dart';

const _adminPassword = String.fromEnvironment('DEMO_ADMIN_PASSWORD');
const _memberPassword = String.fromEnvironment('DEMO_MEMBER_PASSWORD');
const _groupId = String.fromEnvironment('DEMO_GROUP_ID');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> shot(WidgetTester tester, String name) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));
    await binding.takeScreenshot(name);
  }

  Future<void> waitFor(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (finder.evaluate().isNotEmpty) return;
    }
    throw TestFailure('Timed out waiting for $finder');
  }

  Future<void> settleNetwork(WidgetTester tester) async {
    await waitFor(
      tester,
      find.byType(CircularProgressIndicator),
      timeout: const Duration(milliseconds: 400),
    ).catchError((_) {});
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(end) &&
        find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle();
  }

  Finder nav(String label) => find.byKey(ValueKey('nav-$label'));

  void go(WidgetTester tester, String path) =>
      GoRouter.of(tester.element(find.byType(Scaffold).first)).go(path);

  Future<void> login(WidgetTester tester, String user, String password) async {
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Username'),
      user,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      password,
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await waitFor(tester, nav('Dashboard'));
    await settleNetwork(tester);
  }

  Future<void> signOut(WidgetTester tester) async {
    go(tester, '/settings');
    await waitFor(tester, find.widgetWithText(OutlinedButton, 'Sign out'));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Sign out'));
    await waitFor(tester, find.widgetWithText(FilledButton, 'Sign in'));
  }

  testWidgets('README screenshots', (tester) async {
    ambientMotionEnabled = false;
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
    if (nav('Dashboard').evaluate().isNotEmpty) await signOut(tester);
    await shot(tester, '01_sign_in');

    // Group Admin.
    await login(tester, 'aarav', _adminPassword);
    await shot(tester, '02_dashboard');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -560));
    await shot(tester, '03_dashboard_charts');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
    await shot(tester, '04_dashboard_more');

    await tester.tap(nav('Expenses'));
    await settleNetwork(tester);
    await shot(tester, '05_expenses');
    await tester.tap(find.text('Ishita\'s birthday dinner').first);
    await tester.pumpAndSettle();
    await shot(tester, '06_entry_detail');
    await tester.tapAt(const Offset(20, 80)); // close the sheet
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Add transaction'));
    await waitFor(tester, find.text('Add Income'));
    await shot(tester, '07_plus_sheet');
    await tester.tap(find.text('Add Expense'));
    await waitFor(tester, find.widgetWithText(ChoiceChip, 'Food'));
    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '850');
    await tester.tap(find.widgetWithText(ChoiceChip, 'Food'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Description (optional)'),
      'Chai & samosa for the house meeting',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await shot(tester, '08_add_expense');

    go(tester, '/m/groups/$_groupId');
    await settleNetwork(tester);
    await shot(tester, '09_group');
    go(tester, '/m/groups/$_groupId/categories');
    await settleNetwork(tester);
    await shot(tester, '10_categories');
    go(tester, '/notifications');
    await settleNetwork(tester);
    await shot(tester, '11_notifications');

    // Member.
    await signOut(tester);
    await login(tester, 'meera', _memberPassword);
    await shot(tester, '12_member_dashboard');
    await tester.tap(nav('Income'));
    await settleNetwork(tester);
    await shot(tester, '13_member_income');
    await tester.tap(nav('Groups'));
    await settleNetwork(tester);
    await shot(tester, '14_member_groups');
    await signOut(tester);
  });
}
