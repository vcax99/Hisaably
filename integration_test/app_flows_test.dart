// End-to-end UI flows on a real simulator/emulator against the dev backend.
// Run with scripts/run_device_flows.sh <device-id>. It needs the QA accounts'
// passwords as --dart-define values (never stored in the repo).
//
// Covers: wrong password, member login + shell, account screen memberships,
// Groups tab as Group Admin, add/delete expense, offline queue (pending →
// sync, rejected → discard), "+" sheet, sign out, Super Admin login + shell, users list, create user,
// add member to a group, delete user, sign out.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/network/network_status.dart';
import 'package:hisaably/core/sync/transactions_local_data_source.dart';
import 'package:hisaably/core/utils/ist_date.dart';
import 'package:hisaably/core/widgets/wave_background.dart';
import 'package:hisaably/features/groups/application/groups_providers.dart';
import 'package:hisaably/features/transactions/application/transactions_providers.dart';
import 'package:hisaably/features/transactions/domain/transaction.dart';
import 'package:hisaably/main.dart' as app;
import 'package:integration_test/integration_test.dart';
import 'package:uuid/uuid.dart';

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

  Future<void> waitForGone(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (finder.evaluate().isEmpty) return;
    }
    throw TestFailure('Timed out waiting for $finder to disappear');
  }

  /// With several groups the form asks which one first (nothing is added to
  /// a group by accident); the flow always records into QA Roomies.
  Future<void> pickQaRoomiesIfAsked(WidgetTester tester) async {
    await waitFor(
      tester,
      find.byWidgetPredicate(
        (w) =>
            (w is Text && w.data == 'Choose a group first') ||
            (w is ChoiceChip),
      ),
    );
    if (find.text('Choose a group first').evaluate().isEmpty) return;
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('QA Roomies').last);
    await tester.pumpAndSettle();
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

    ambientMotionEnabled = false; // the flow uses pumpAndSettle
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
    // "Current balance" (one group) or "Combined balance" (several).
    await waitFor(tester, find.textContaining('balance'));
    await shot(tester, '03_member_home');
    // Phase 8: charts below the fold.
    await tester.scrollUntilVisible(
      find.text('Income vs expense'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await shot(tester, '03b_dashboard_charts');
    await tester.scrollUntilVisible(
      find.text('Recent transactions'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await shot(tester, '03c_dashboard_trend_recent');

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

    // 3c. Notifications (Phases 11–12): the monthly job's "New Month
    // Started" is listed; "Mark all read" clears unread dots and the badge.
    await tester.tap(find.byTooltip('Notifications'));
    await waitFor(tester, find.textContaining('New Month Started'));
    await shot(tester, '04d_notifications');
    // Auto-delete setting (server-side): keep the QA account's history
    // ("Never"), so this flow always finds its monthly notification.
    await waitFor(tester, find.byKey(const Key('retention-dropdown')));
    final retention = find.descendant(
      of: find.byKey(const Key('retention-dropdown')),
      matching: find.text('Never'),
    );
    if (retention.evaluate().isEmpty) {
      await tester.tap(find.byKey(const Key('retention-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Never').last);
      await waitFor(tester, find.text('Read notifications will be kept'));
      await waitFor(tester, retention);
    }
    // The ⋮ menu has "Mark all as read" and "Delete all" (not used here:
    // it would delete the monthly notification for good).
    await tester.tap(find.byKey(const Key('notifications-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('delete-all')), findsOneWidget);
    await shot(tester, '04e_notifications_menu');
    if (find.byKey(const Key('unread-dot')).evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const Key('mark-all-read')));
      await waitForGone(tester, find.byKey(const Key('unread-dot')));
    } else {
      await tester.tapAt(const Offset(10, 10)); // close the menu
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const Key('unread-dot')), findsNothing);
    // Tapping a monthly notification opens the Dashboard.
    await tester.tap(find.textContaining('New Month Started').first);
    await waitFor(tester, find.textContaining('balance'));
    await waitForGone(
      tester,
      find.byWidgetPredicate((w) => w is Badge && w.isLabelVisible),
    );

    // 4. "+" → Add Expense (Phase 7): real expense in QA Roomies.
    await tester.tap(find.bySemanticsLabel('Add transaction'));
    await waitFor(tester, find.text('Add Income'));
    await shot(tester, '05_plus_sheet');
    await tester.tap(find.text('Add Expense'));
    await pickQaRoomiesIfAsked(tester);
    await waitFor(tester, find.widgetWithText(ChoiceChip, 'Food'));
    final note =
        'device-flow ${DateTime.now().millisecondsSinceEpoch % 100000}';
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Amount'),
      '123.45',
    );
    await tester.tap(find.widgetWithText(ChoiceChip, 'Food'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Description (optional)'),
      note,
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await shot(tester, '05b_add_expense_form');
    await tester.tap(find.text('Save expense'));
    await waitFor(tester, find.text('Expense of ₹123.45 added'));
    await tester.pumpAndSettle(); // let the form's exit transition finish

    // 4b. It shows up in the Expenses tab; as Group Admin, delete it again.
    await tester.tap(nav('Expenses'));
    await waitFor(tester, find.textContaining(note));
    // Server DATEs must be calendar dates: today's group is labelled "Today".
    expect(find.text('Today'), findsWidgets);
    await shot(tester, '05c_expenses_list');
    await tester.tap(find.textContaining(note));
    await waitFor(tester, find.widgetWithText(OutlinedButton, 'Delete'));
    // Who added it (server-side entry history).
    await waitFor(tester, find.textContaining('QA Member ·'));
    expect(find.text('Edited by'), findsNothing);
    await shot(tester, '05d_expense_detail');
    // Edit it → "Edited by" appears.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Edit'));
    await waitFor(tester, find.text('Save changes'));
    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '124');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await waitFor(tester, find.text('−₹124'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(note));
    await waitFor(tester, find.text('Edited by'));
    expect(find.textContaining('QA Member ·'), findsNWidgets(2));
    await shot(tester, '05e_expense_detail_edited');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await waitFor(tester, find.text('Expense deleted'));
    expect(find.textContaining(note), findsNothing);

    // 4c. Offline queue (Phase 9) on the device's real SQLite: an entry
    // saved while offline shows "Pending", then "Sync now" sends it.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    final roomies = (await container.read(groupsListProvider.future))
        .firstWhere((g) => g.name == 'QA Roomies');
    final local = container.read(transactionsLocalDataSourceProvider);
    final offlineNote = 'offline-$note';
    await local.insertPending(
      Transaction(
        id: const Uuid().v4(),
        groupId: roomies.id,
        type: TransactionType.expense,
        amountPaise: 4321,
        category: 'Food',
        description: offlineNote,
        date: IstDate.today(),
      ),
    );
    container.invalidate(transactionListProvider);
    await waitFor(tester, find.textContaining(offlineNote));
    await waitFor(tester, find.byKey(const Key('sync-now')));
    expect(find.text('Pending'), findsOneWidget);
    await shot(tester, '05e_pending_entry');
    await tester.tap(find.byKey(const Key('sync-now')));
    await waitFor(tester, find.text('All changes synced'));
    await tester.pumpAndSettle();
    await waitFor(tester, find.textContaining(offlineNote));
    expect(find.text('Pending'), findsNothing);
    expect(find.byKey(const Key('sync-banner')), findsNothing);
    // It is on the server now: the Group Admin can delete it.
    await tester.tap(find.textContaining(offlineNote));
    await waitFor(tester, find.widgetWithText(OutlinedButton, 'Delete'));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await waitFor(tester, find.text('Expense deleted'));

    // 4d. A queued entry the server rejects (future date) → "Not synced",
    // with the reason, and can be discarded.
    final rejectedNote = 'rejected-$note';
    await local.insertPending(
      Transaction(
        id: const Uuid().v4(),
        groupId: roomies.id,
        type: TransactionType.expense,
        amountPaise: 999,
        category: 'Food',
        description: rejectedNote,
        date: IstDate.today().add(const Duration(days: 1)),
      ),
    );
    container.invalidate(transactionListProvider);
    await waitFor(tester, find.byKey(const Key('sync-now')));
    await tester.tap(find.byKey(const Key('sync-now')));
    await waitFor(tester, find.text('Not synced'));
    await shot(tester, '05f_failed_entry');
    await tester.tap(find.textContaining(rejectedNote));
    await waitFor(tester, find.byKey(const Key('tx-discard')));
    expect(find.textContaining('future'), findsOneWidget);
    await shot(tester, '05g_failed_detail');
    await tester.tap(find.byKey(const Key('tx-discard')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Discard'));
    await waitFor(tester, find.text('Expense discarded'));
    await tester.pumpAndSettle();
    expect(find.textContaining(rejectedNote), findsNothing);
    expect(find.byKey(const Key('sync-banner')), findsNothing);

    // 4e. No network (simulated in the app's network layer, so it also
    // runs on the iOS simulator): the form saves instantly offline, and the
    // entry syncs by itself when the network returns.
    expect(NetworkStatus.instance.hasNetwork, isTrue);
    NetworkStatus.instance.debugSet(false);
    final noNetNote = 'nonet-$note';
    await tester.tap(find.bySemanticsLabel('Add transaction'));
    await waitFor(tester, find.text('Add Expense'));
    await tester.tap(find.text('Add Expense'));
    await pickQaRoomiesIfAsked(tester);
    await waitFor(tester, find.widgetWithText(ChoiceChip, 'Food'));
    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '12');
    await tester.tap(find.widgetWithText(ChoiceChip, 'Food'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Description (optional)'),
      noNetNote,
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final saveClock = Stopwatch()..start();
    await tester.tap(find.text('Save expense'));
    // Saved and listed as Pending right away (no network wait).
    await waitFor(
      tester,
      find.text('Pending'),
      timeout: const Duration(seconds: 3),
    );
    expect(saveClock.elapsed, lessThan(const Duration(seconds: 3)));
    await tester.pumpAndSettle(); // the form is still fading out
    expect(find.textContaining(noNetNote), findsOneWidget);
    // Snackbars queue behind the previous step's message.
    await waitFor(
      tester,
      find.text('Expense saved offline · will sync when online'),
    );
    await shot(tester, '05h_no_network_saved');
    NetworkStatus.instance.debugSet(true);
    await waitForGone(tester, find.text('Pending'));
    expect(find.byKey(const Key('sync-banner')), findsNothing);
    await tester.tap(find.textContaining(noNetNote));
    await waitFor(tester, find.widgetWithText(OutlinedButton, 'Delete'));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await waitFor(tester, find.text('Expense deleted'));

    await tester.tap(nav('Dashboard'));
    await tester.pumpAndSettle();

    // 5. Sign out.
    await signOutVia(tester, find.byTooltip('Account'));

    // 6. Super Admin login → admin shell.
    await login(tester, 'qa_admin', _adminPassword);
    await waitFor(tester, nav('Users'));
    expect(nav('Expenses'), findsNothing);
    await waitFor(tester, find.text('All groups'));
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
