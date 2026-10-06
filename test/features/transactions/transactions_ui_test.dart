import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hisaably/app.dart';
import 'package:hisaably/core/utils/ist_date.dart';
import 'package:hisaably/features/auth/data/auth_repository.dart';
import 'package:hisaably/features/auth/domain/user_context.dart';
import 'package:hisaably/features/groups/data/groups_repository.dart';
import 'package:hisaably/features/notifications/data/notifications_repository.dart';
import 'package:hisaably/features/notifications/domain/app_notification.dart';
import 'package:hisaably/features/transactions/data/transactions_repository.dart';
import 'package:hisaably/features/transactions/domain/transaction.dart';
import 'package:hisaably/features/users/data/users_repository.dart';
import 'package:hisaably/routing/app_router.dart';
import 'package:hisaably/routing/routes.dart';

import '../../helpers/fake_admin_repositories.dart';
import '../../helpers/fake_auth_repository.dart';
import '../../helpers/fake_notifications_repository.dart';
import '../../helpers/fake_transactions_repository.dart';

UserContext _ctx({bool groupAdmin = false}) => buildContext(
  id: 'me',
  memberships: [
    GroupMembership(
      groupId: 'g1',
      groupName: 'Roomies',
      groupStatus: RecordStatus.active,
      groupRole: groupAdmin ? GroupRole.groupAdmin : GroupRole.member,
      membershipStatus: RecordStatus.active,
    ),
  ],
);

Future<(GoRouter, FakeLedger)> _pump(
  WidgetTester tester, {
  bool groupAdmin = false,
  FakeLedger? ledger,
  String location = Routes.memberDashboard,
  List<AppNotification> notifications = const [],
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  final groups = FakeAdminBackend()..addGroup('Roomies', id: 'g1');
  final db = ledger ?? (FakeLedger()..seedCategories('g1'));
  db.canManage = groupAdmin;
  final container = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(
          accounts: {'asha': FakeAccount('pw', _ctx(groupAdmin: groupAdmin))},
          signedInAs: 'asha',
        ),
      ),
      usersRepositoryProvider.overrideWithValue(FakeUsersRepository(groups)),
      groupsRepositoryProvider.overrideWithValue(FakeGroupsRepository(groups)),
      transactionsRepositoryProvider.overrideWithValue(
        FakeTransactionsRepository(db),
      ),
      categoriesRepositoryProvider.overrideWithValue(
        FakeCategoriesRepository(db),
      ),
      notificationsRepositoryProvider.overrideWithValue(
        FakeNotificationsRepository(notifications),
      ),
    ],
    retry: (_, _) => null,
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const HisaablyApp()),
  );
  await tester.pumpAndSettle();
  final router = container.read(appRouterProvider)..go(location);
  await tester.pumpAndSettle();
  return (router, db);
}

Future<void> _openAdd(WidgetTester tester, GoRouter router, String type) async {
  unawaited(router.push(Routes.addTransaction(type)));
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.widgetWithText(TextFormField, label);

void main() {
  group('Add transaction', () {
    testWidgets('validates amount and category', (tester) async {
      final (router, db) = await _pump(tester);
      await _openAdd(tester, router, 'expense');
      expect(find.text('Roomies'), findsOneWidget); // single group, read-only

      await tester.tap(find.text('Save expense'));
      await tester.pumpAndSettle();
      expect(find.text('Enter an amount'), findsOneWidget);
      expect(db.transactions, isEmpty);

      await tester.enterText(_field('Amount'), '850');
      await tester.tap(find.text('Save expense'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a category for the expense.'), findsOneWidget);
      expect(db.transactions, isEmpty);
    });

    testWidgets('adds an expense dated today and returns', (tester) async {
      final (router, db) = await _pump(tester);
      await _openAdd(tester, router, 'expense');

      await tester.enterText(_field('Amount'), '850.50');
      await tester.tap(find.widgetWithText(ChoiceChip, 'Food'));
      await tester.enterText(_field('Description (optional)'), 'Lunch');
      await tester.pumpAndSettle();
      expect(find.text('Today'), findsOneWidget);
      await tester.tap(find.text('Save expense'));
      await tester.pumpAndSettle();

      final t = db.transactions.values.single;
      expect(t.amountPaise, 85050);
      expect(t.category, 'Food');
      expect(t.description, 'Lunch');
      expect(t.date, IstDate.today());
      expect(router.state.uri.path, Routes.memberDashboard);
      expect(find.text('Expense of ₹850.50 added'), findsOneWidget);
    });

    testWidgets('"Other" creates a new category for the group', (tester) async {
      final (router, db) = await _pump(tester);
      await _openAdd(tester, router, 'expense');
      await tester.enterText(_field('Amount'), '300');
      await tester.tap(find.widgetWithText(ChoiceChip, 'Other'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('New category name'), 'Pets');
      await tester.tap(find.text('Save expense'));
      await tester.pumpAndSettle();

      expect(db.transactions.values.single.category, 'Pets');
      expect(db.categories.map((c) => c.name), contains('Pets'));
    });

    testWidgets('income category is optional', (tester) async {
      final (router, db) = await _pump(tester);
      await _openAdd(tester, router, 'income');
      expect(find.text('Category (optional)'), findsOneWidget);
      await tester.enterText(_field('Amount'), '20000');
      await tester.tap(find.text('Save income'));
      await tester.pumpAndSettle();
      final t = db.transactions.values.single;
      expect(t.type, TransactionType.income);
      expect(t.category, isNull);
      expect(t.amountPaise, 2000000);
    });
  });

  group('Lists', () {
    FakeLedger seeded() {
      final db = FakeLedger()..seedCategories('g1');
      final today = IstDate.today();
      db
        ..seed('g1', TransactionType.expense, 85000, category: 'Food')
        ..seed(
          'g1',
          TransactionType.expense,
          150000,
          category: 'Rent',
          date: today.day > 1 ? today.subtract(const Duration(days: 1)) : today,
        )
        ..seed('g1', TransactionType.income, 2000000, category: 'Salary');
      return db;
    }

    testWidgets('Expenses tab: only expenses, total and day headers', (
      tester,
    ) async {
      await _pump(tester, ledger: seeded(), location: Routes.memberExpenses);
      expect(find.text('Food'), findsOneWidget);
      expect(find.text('Rent'), findsOneWidget);
      expect(find.text('Salary'), findsNothing);
      expect(find.text('−₹850'), findsOneWidget);
      expect(find.text('₹2,350'), findsOneWidget); // server-side total
      expect(find.text('Today'), findsOneWidget);
    });

    testWidgets('member sees details but no edit/delete', (tester) async {
      await _pump(tester, ledger: seeded(), location: Routes.memberExpenses);
      await tester.tap(find.text('Food'));
      await tester.pumpAndSettle();
      expect(find.text('Description'), findsNothing);
      expect(find.text('Roomies'), findsOneWidget);
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('member edits their own entry, not others\'', (tester) async {
      final db = seeded();
      final food = db.transactions.values.firstWhere(
        (t) => t.category == 'Food',
      );
      db.ownIds.add(food.id);
      await _pump(tester, ledger: db, location: Routes.memberExpenses);

      await tester.tap(find.text('Rent')); // added by someone else
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      await tester.tapAt(const Offset(20, 80));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Food')); // their own
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Amount'), '910');
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(db.transactions[food.id]!.amountPaise, 91000);
      expect(find.text('−₹910'), findsOneWidget);
    });

    testWidgets('details show who added and who last edited', (tester) async {
      final db = seeded();
      final food = db.transactions.values.firstWhere(
        (t) => t.category == 'Food',
      );
      db.histories[food.id] = TransactionHistory(
        created: HistoryEvent(
          name: 'Meera Iyer',
          at: DateTime(2026, 10, 5, 9, 41),
        ),
        updated: HistoryEvent(
          name: 'Aarav Sharma',
          at: DateTime(2026, 10, 5, 18, 2),
        ),
      );
      await _pump(tester, ledger: db, location: Routes.memberExpenses);
      await tester.tap(find.text('Food'));
      await tester.pumpAndSettle();
      expect(find.text('Added by'), findsOneWidget);
      expect(find.text('Meera Iyer · 5 Oct 2026, 9:41 AM'), findsOneWidget);
      expect(find.text('Edited by'), findsOneWidget);
      expect(find.text('Aarav Sharma · 5 Oct 2026, 6:02 PM'), findsOneWidget);
    });

    testWidgets('old entries: "Not recorded"; deleted users; no edit line', (
      tester,
    ) async {
      final db = seeded();
      final food = db.transactions.values.firstWhere(
        (t) => t.category == 'Food',
      );
      db.histories[food.id] = TransactionHistory(
        created: HistoryEvent(name: null, at: DateTime(2026, 10, 5, 9, 41)),
      );
      await _pump(tester, ledger: db, location: Routes.memberExpenses);
      await tester.tap(find.text('Food'));
      await tester.pumpAndSettle();
      expect(find.text('Deleted user · 5 Oct 2026, 9:41 AM'), findsOneWidget);
      expect(find.text('Edited by'), findsNothing);

      await tester.tapAt(const Offset(20, 80)); // close the sheet
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rent'));
      await tester.pumpAndSettle();
      expect(find.text('Not recorded'), findsOneWidget);
    });

    testWidgets('group admin edits an expense', (tester) async {
      final (_, db) = await _pump(
        tester,
        groupAdmin: true,
        ledger: seeded(),
        location: Routes.memberExpenses,
      );
      await tester.tap(find.text('Food'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('Edit expense'), findsOneWidget);
      expect(find.text('850'), findsOneWidget);

      await tester.enterText(_field('Amount'), '900');
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      final food = db.transactions.values.firstWhere(
        (t) => t.category == 'Food',
      );
      expect(food.amountPaise, 90000);
      expect(food.syncVersion, 2);
      expect(find.text('−₹900'), findsOneWidget);
    });

    testWidgets('group admin deletes an expense', (tester) async {
      final (_, db) = await _pump(
        tester,
        groupAdmin: true,
        ledger: seeded(),
        location: Routes.memberExpenses,
      );
      await tester.tap(find.text('Rent'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(db.transactions.values.any((t) => t.category == 'Rent'), isFalse);
      expect(find.text('Rent'), findsNothing);
    });

    testWidgets('loads the next page when scrolling', (tester) async {
      final db = FakeLedger()..seedCategories('g1');
      for (var i = 0; i < 35; i++) {
        db.seed('g1', TransactionType.expense, 100 + i, category: 'Food');
      }
      await _pump(tester, ledger: db, location: Routes.memberExpenses);
      expect(db.listCalls.whereType<TransactionCursor>(), isEmpty);

      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, -4000),
        3000,
      );
      await tester.pumpAndSettle();
      expect(db.listCalls.whereType<TransactionCursor>(), isNotEmpty);
      expect(find.text('−₹1'), findsOneWidget); // the 35th (oldest) row
    });
  });

  group('Group screens', () {
    testWidgets('group ledger shows both totals and entries', (tester) async {
      final db = FakeLedger()..seedCategories('g1');
      db
        ..seed('g1', TransactionType.expense, 85000, category: 'Food')
        ..seed('g1', TransactionType.income, 2000000, category: 'Salary');
      await _pump(tester, ledger: db, location: Routes.memberGroup('g1'));
      await tester.tap(find.text('Transactions'));
      await tester.pumpAndSettle();
      expect(find.text('Roomies · Ledger'), findsOneWidget);
      expect(find.text('Total spent'), findsOneWidget);
      expect(find.text('Total received'), findsOneWidget);
      expect(find.text('+₹20,000'), findsOneWidget);
      expect(find.text('−₹850'), findsOneWidget);
    });

    testWidgets('categories: hidden for members, rename/delete for admins', (
      tester,
    ) async {
      await _pump(tester, location: Routes.memberGroup('g1'));
      expect(find.text('Categories'), findsNothing);
    });

    testWidgets('group admin renames and deletes a category', (tester) async {
      final (_, db) = await _pump(
        tester,
        groupAdmin: true,
        location: Routes.memberGroup('g1'),
      );
      await tester.tap(find.text('Categories'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Category actions').first); // Food
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Meals');
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();
      expect(db.categories.map((c) => c.name), contains('Meals'));
      expect(find.text('Meals'), findsOneWidget);

      await tester.tap(find.byTooltip('Category actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(
        db.categories.firstWhere((c) => c.name == 'Meals').isActive,
        isFalse,
      );
      expect(find.text('Deleted'), findsOneWidget);
    });
  });

  group('Notification tap-through', () {
    AppNotification note(
      String id,
      NotificationType type, {
      String? transactionId,
    }) => AppNotification(
      id: id,
      type: type,
      title: 'note $id',
      body: 'body $id',
      isRead: false,
      createdAt: DateTime.utc(2026, 9, 26, 10),
      groupId: 'g1',
      transactionId: transactionId,
    );

    testWidgets('expense → Expenses tab + that entry\'s details', (
      tester,
    ) async {
      final ledger = FakeLedger()..seedCategories('g1');
      final t = ledger.seed(
        'g1',
        TransactionType.expense,
        85000,
        category: 'Food',
        description: 'Team lunch',
      );
      final (router, _) = await _pump(
        tester,
        ledger: ledger,
        notifications: [
          note('n1', NotificationType.expenseAdded, transactionId: t.id),
        ],
      );
      unawaited(router.push(Routes.notifications));
      await tester.pumpAndSettle();
      await tester.tap(find.text('note n1'));
      await tester.pumpAndSettle();
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        Routes.memberExpenses,
      );
      expect(find.text('Team lunch'), findsWidgets);
      expect(find.text('Description'), findsOneWidget, reason: 'detail sheet');
    });

    testWidgets('deleted entry → message, no navigation', (tester) async {
      final ledger = FakeLedger()..seedCategories('g1');
      ledger.deletedTypes['gone'] = TransactionType.income;
      final (router, _) = await _pump(
        tester,
        ledger: ledger,
        notifications: [
          note('n2', NotificationType.incomeAdded, transactionId: 'gone'),
        ],
      );
      unawaited(router.push(Routes.notifications));
      await tester.pumpAndSettle();
      await tester.tap(find.text('note n2'));
      await tester.pumpAndSettle();
      expect(find.text('This income has been deleted.'), findsOneWidget);
      // Stays on the Notifications screen.
      expect(find.text('note n2'), findsOneWidget);
    });

    testWidgets('entry no longer visible → message', (tester) async {
      final (router, _) = await _pump(
        tester,
        notifications: [
          note('n3', NotificationType.expenseAdded, transactionId: 'nope'),
        ],
      );
      unawaited(router.push(Routes.notifications));
      await tester.pumpAndSettle();
      await tester.tap(find.text('note n3'));
      await tester.pumpAndSettle();
      expect(
        find.text('This expense is no longer available to you.'),
        findsOneWidget,
      );
    });

    testWidgets('monthly → Dashboard', (tester) async {
      final (router, _) = await _pump(
        tester,
        location: Routes.memberExpenses,
        notifications: [note('n4', NotificationType.monthStarted)],
      );
      unawaited(router.push(Routes.notifications));
      await tester.pumpAndSettle();
      await tester.tap(find.text('note n4'));
      await tester.pumpAndSettle();
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        Routes.memberDashboard,
      );
    });
  });
}
