// End-to-end UI flows on a real simulator/emulator against the dev backend.
// Run with scripts/run_device_flows.sh <device-id>. It needs the QA accounts'
// passwords as --dart-define values (never stored in the repo).
//
// Covers: wrong password, member login + shell, account screen memberships,
// Groups tab as Group Admin, "+" sheet, sign out, Super Admin login + shell, users list, create user,
// add member to a group, delete user, sign out.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/main.dart' as app;
import 'package:integration_test/integration_test.dart';

const _adminPassword = String.fromEnvironment('QA_ADMIN_PASSWORD');
const _memberPassword = String.fromEnvironment('QA_MEMBER_PASSWORD');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  var surfaceConverted = false;

  Future<void> shot(WidgetTester tester, String name) async {
    if (Platform.isAndroid && !surfaceConverted) {
      await binding.convertFlutterSurfaceToImage();
      surfaceConverted = true;
    }
    await tester.pumpAndSettle();
    final platform = Platform.isIOS ? 'ios' : 'android';
    await binding.takeScreenshot('${platform}_$name');
  }

  /// Pumps until [finder] matches (network calls take real time here).
  Future<void> waitFor(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (finder.evaluate().isNotEmpty) return;
    }
    throw TestFailure('Timed out waiting for $finder');
  }

  Finder nav(String label) => find.byKey(ValueKey('nav-$label'));

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
  }

  Future<void> signOutVia(WidgetTester tester, Finder openAccount) async {
    await tester.tap(openAccount);
    await waitFor(tester, find.widgetWithText(OutlinedButton, 'Sign out'));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Sign out'));
    await waitFor(tester, find.widgetWithText(FilledButton, 'Sign in'));
  }

  testWidgets('Phases 1–5 flows against the dev backend', (tester) async {
    expect(
      _adminPassword.isNotEmpty && _memberPassword.isNotEmpty,
      isTrue,
      reason: 'Pass QA_ADMIN_PASSWORD and QA_MEMBER_PASSWORD via --dart-define',
    );

    await app.main();
    // Start from a signed-out state regardless of a previous run.
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
    if (nav('Dashboard').evaluate().isNotEmpty) {
      await signOutVia(tester, find.byTooltip('Account'));
    }
    await shot(tester, '01_login');

    // 1. Wrong password.
    await login(tester, 'qa_member', 'definitely-wrong-1');
    await waitFor(tester, find.text('Incorrect username or password.'));
    await shot(tester, '02_wrong_password');

    // 2. Member login → member shell.
    await login(tester, 'qa_member', _memberPassword);
    await waitFor(tester, nav('Expenses'));
    expect(nav('Users'), findsNothing);
    await shot(tester, '03_member_home');

    // 3. Account screen shows real memberships.
    await tester.tap(find.byTooltip('Account'));
    await waitFor(tester, find.text('QA Roomies'));
    expect(find.text('Group Admin'), findsOneWidget);
    await shot(tester, '04_member_account');
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 3b. Groups tab (Phase 6): qa_member is Group Admin of QA Roomies.
    await tester.tap(nav('Groups'));
    await waitFor(tester, find.text('QA Roomies'));
    await shot(tester, '04b_member_groups');
    await tester.tap(find.text('QA Roomies'));
    await waitFor(tester, find.text('Rename group'));
    expect(find.text('Add member'), findsNothing);
    expect(find.text('Disable group'), findsNothing);
    await shot(tester, '04c_group_admin_detail');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(nav('Dashboard'));
    await tester.pumpAndSettle();

    // 4. "+" sheet.
    await tester.tap(find.bySemanticsLabel('Add transaction'));
    await waitFor(tester, find.text('Add Income'));
    await shot(tester, '05_plus_sheet');
    await tester.tapAt(const Offset(200, 150)); // dismiss via the barrier
    await tester.pumpAndSettle();

    // 5. Sign out.
    await signOutVia(tester, find.byTooltip('Account'));

    // 6. Super Admin login → admin shell.
    await login(tester, 'qa_admin', _adminPassword);
    await waitFor(tester, nav('Users'));
    expect(nav('Expenses'), findsNothing);
    await shot(tester, '06_admin_home');

    // 7. Users list (sorted A→Z).
    await tester.tap(nav('Users'));
    await waitFor(tester, find.text('@qa_member'));
    await shot(tester, '07_users');

    // 8. Create a throwaway user through the form.
    final tempUsername =
        'qa_it_${DateTime.now().millisecondsSinceEpoch % 100000}';
    await tester.tap(find.byTooltip('New user'));
    await waitFor(tester, find.widgetWithText(TextFormField, 'Full name'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Full name'),
      'QA Device Temp',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Username'),
      tempUsername,
    );
    await tester.tap(find.text('Generate password'));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await shot(tester, '08_new_user_form');
    await tester.tap(find.widgetWithText(FilledButton, 'Create user'));
    await waitFor(tester, find.text('User created'));
    await shot(tester, '09_user_created');
    await tester.tap(find.widgetWithText(TextButton, 'Done'));
    await waitFor(tester, find.text('@$tempUsername'));

    // 9. Add the new user to QA Roomies.
    await tester.tap(nav('Groups'));
    await waitFor(tester, find.text('QA Roomies'));
    await shot(tester, '10_groups');
    await tester.tap(find.text('QA Roomies'));
    // Wait for the member list: "Add member" is disabled until it loads.
    await waitFor(tester, find.text('@qa_member'));
    await tester.tap(find.text('Add member'));
    await waitFor(tester, find.text('QA Device Temp'));
    await tester.tap(find.text('QA Device Temp'));
    await waitFor(tester, find.text('@$tempUsername'));
    await shot(tester, '11_group_member_added');

    // 10. Delete the throwaway user (also cleans up).
    await tester.tap(nav('Users'));
    await waitFor(tester, find.text('QA Device Temp'));
    await tester.tap(find.text('QA Device Temp'));
    await waitFor(tester, find.text('Delete user'));
    await tester.ensureVisible(find.text('Delete user'));
    await tester.tap(find.text('Delete user'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await waitFor(tester, find.text('User deleted'));
    expect(find.text('@$tempUsername'), findsNothing);
    await shot(tester, '12_user_deleted');

    // 11. Sign out from More → Account.
    await tester.tap(nav('More'));
    await waitFor(tester, find.text('Account'));
    await signOutVia(tester, find.text('Account'));
    await shot(tester, '13_signed_out');
  });
}
