import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/app.dart';
import 'package:hisaably/core/utils/ist_date.dart';
import 'package:hisaably/features/auth/data/auth_repository.dart';
import 'package:hisaably/features/auth/domain/user_context.dart';
import 'package:hisaably/features/dashboard/data/dashboard_repository.dart';
import 'package:hisaably/features/dashboard/domain/dashboard.dart';
import 'package:hisaably/features/groups/data/groups_repository.dart';
import 'package:hisaably/features/transactions/domain/transaction.dart';
import 'package:hisaably/routing/app_router.dart';
import 'package:hisaably/routing/routes.dart';

import '../../helpers/fake_admin_repositories.dart';
import '../../helpers/fake_auth_repository.dart';

class FakeDashboardRepository implements DashboardRepository {
  final calls = <({String? groupId, DateTime month})>[];
  List<GroupBalance> groupBalances = const [];

  @override
  Future<List<GroupBalance>> getGroupBalances({
    required DateTime month,
  }) async => groupBalances;
  List<CategoryTotal> breakdown = const [];
  List<Transaction> recent = const [];

  @override
  Future<DashboardData> getDashboard({
    String? groupId,
    required DateTime month,
  }) async {
    calls.add((groupId: groupId, month: month));
    final trend = [
      for (var i = 5; i >= 0; i--)
        MonthSummary(
          month: DateTime.utc(month.year, month.month - i),
          openingPaise: 1000000,
          incomePaise: 5000000,
          expensePaise: 3500000,
          closingPaise: 2500000,
        ),
    ];
    return DashboardData(
      month: month,
      currentBalancePaise: 1850000,
      summary: MonthSummary(
        month: month,
        openingPaise: 1500000,
        incomePaise: 2000000,
        expensePaise: 1650000,
        closingPaise: 1850000,
      ),
      trend: trend,
      expenseBreakdown: breakdown,
      recent: recent,
    );
  }

  @override
  Future<AdminOverview> getAdminOverview() async => const AdminOverview(
    usersTotal: 7,
    usersActive: 6,
    usersDisabled: 1,
    groupsTotal: 3,
    groupsActive: 2,
  );
}

Future<FakeDashboardRepository> _pump(
  WidgetTester tester, {
  required UserContext context,
  FakeAdminBackend? groups,
  FakeDashboardRepository? dashboard,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final repo = dashboard ?? FakeDashboardRepository();
  final g = groups ?? (FakeAdminBackend()..addGroup('Roomies', id: 'g1'));
  final container = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(
          accounts: {'me': FakeAccount('pw', context)},
          signedInAs: 'me',
        ),
      ),
      groupsRepositoryProvider.overrideWithValue(FakeGroupsRepository(g)),
      dashboardRepositoryProvider.overrideWithValue(repo),
    ],
    retry: (_, _) => null,
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const HisaablyApp()),
  );
  await tester.pumpAndSettle();
  return repo;
}

UserContext _member() => buildContext(
  id: 'me',
  username: 'me',
  memberships: const [
    GroupMembership(
      groupId: 'g1',
      groupName: 'Roomies',
      groupStatus: RecordStatus.active,
      groupRole: GroupRole.member,
      membershipStatus: RecordStatus.active,
    ),
  ],
);

void main() {
  final thisMonth = DateTime.utc(IstDate.today().year, IstDate.today().month);

  testWidgets('member dashboard: balance, month totals, charts, recent', (
    tester,
  ) async {
    final repo = FakeDashboardRepository()
      ..breakdown = const [
        CategoryTotal(category: 'Rent', totalPaise: 1000000, count: 1),
        CategoryTotal(category: 'Food', totalPaise: 400000, count: 5),
        CategoryTotal(category: 'Travel', totalPaise: 100000, count: 1),
        CategoryTotal(category: 'Health', totalPaise: 50000, count: 1),
        CategoryTotal(category: 'Shopping', totalPaise: 50000, count: 1),
        CategoryTotal(category: 'Pets', totalPaise: 30000, count: 1),
        CategoryTotal(category: 'Gifts', totalPaise: 20000, count: 1),
      ]
      ..recent = [
        Transaction(
          id: 't1',
          groupId: 'g1',
          type: TransactionType.expense,
          amountPaise: 85000,
          category: 'Food',
          date: IstDate.today(),
        ),
      ];
    await _pump(tester, context: _member(), dashboard: repo);

    expect(repo.calls.single, (groupId: 'g1', month: thisMonth));
    expect(find.text('Roomies'), findsOneWidget);
    expect(find.text('Current balance'), findsOneWidget);
    expect(find.text('₹18,500'), findsOneWidget);
    expect(find.textContaining('Opening ₹15,000'), findsOneWidget);
    expect(find.text('₹20,000'), findsOneWidget); // month income
    expect(find.text('₹16,500'), findsOneWidget); // month expense

    // Donut legend: top 5 + "Other" (Pets + Gifts = ₹500).
    expect(find.text('Rent'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);
    expect(find.text('Pets'), findsNothing);

    await tester.scrollUntilVisible(find.text('Recent transactions'), 300);
    expect(find.text('Income vs expense'), findsOneWidget);
    expect(find.text('Balance trend'), findsOneWidget);
    expect(find.text('−₹850'), findsOneWidget);
  });

  testWidgets('month switcher loads the previous month', (tester) async {
    final repo = await _pump(tester, context: _member());
    await tester.tap(find.byTooltip('Previous month'));
    await tester.pumpAndSettle();
    expect(
      repo.calls.last.month,
      DateTime.utc(thisMonth.year, thisMonth.month - 1),
    );
    expect(find.textContaining('Balance at end of'), findsOneWidget);
    // Can't go past the current month.
    await tester.tap(find.byTooltip('Next month'));
    await tester.pumpAndSettle();
    final next = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.chevron_right_rounded),
    );
    expect(next.onPressed, isNull);
  });

  testWidgets('super admin: counts and All groups by default', (tester) async {
    final groups = FakeAdminBackend()
      ..addGroup('Roomies', id: 'g1')
      ..addGroup('Trip', id: 'g2');
    final repo = await _pump(
      tester,
      context: superAdminContext,
      groups: groups,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HisaablyApp)),
    );
    expect(
      container.read(appRouterProvider).state.uri.path,
      Routes.adminDashboard,
    );
    expect(repo.calls.single.groupId, isNull);
    expect(find.text('All groups'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.text('6 active · 1 disabled'), findsOneWidget);
    expect(find.text('2 active'), findsOneWidget);
    expect(find.text('No expenses this month'), findsOneWidget);
  });

  testWidgets('all groups: dropdown + By group; tapping a group opens it', (
    tester,
  ) async {
    final groups = FakeAdminBackend()
      ..addGroup('Roomies', id: 'g1')
      ..addGroup('Trip', id: 'g2');
    final repo = FakeDashboardRepository()
      ..groupBalances = const [
        GroupBalance(
          groupId: 'g1',
          name: 'Roomies',
          isActive: true,
          currentBalancePaise: 1200000,
          monthIncomePaise: 500000,
          monthExpensePaise: 85000,
        ),
        GroupBalance(
          groupId: 'g2',
          name: 'Trip',
          isActive: true,
          currentBalancePaise: 650000,
          monthIncomePaise: 0,
          monthExpensePaise: 120000,
        ),
      ];
    await _pump(
      tester,
      context: superAdminContext,
      groups: groups,
      dashboard: repo,
    );
    expect(find.byKey(const Key('group-dropdown')), findsOneWidget);
    expect(find.text('Combined balance'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('by-group')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('₹12,000'), findsOneWidget);
    expect(find.text('₹6,500'), findsOneWidget);
    expect(
      find.textContaining('−₹1,200', findRichText: true),
      findsOneWidget,
      reason: 'Trip expense',
    );

    await tester.tap(find.text('₹6,500'));
    await tester.pumpAndSettle();
    expect(repo.calls.last.groupId, 'g2');
    expect(
      find.descendant(
        of: find.byKey(const Key('group-dropdown')),
        matching: find.text('Trip'),
      ),
      findsOneWidget,
      reason: 'dropdown follows the By-group tap',
    );
    expect(find.byKey(const Key('by-group')), findsNothing);
    expect(find.text('Current balance'), findsOneWidget);
  });

  testWidgets('one group: no dropdown, no By group', (tester) async {
    await _pump(tester, context: _member());
    expect(find.byKey(const Key('group-dropdown')), findsNothing);
    expect(find.byKey(const Key('by-group')), findsNothing);
    expect(find.text('Roomies'), findsWidgets);
  });

  testWidgets('member without groups sees an empty state', (tester) async {
    await _pump(
      tester,
      context: buildContext(id: 'me', username: 'me', memberships: const []),
      groups: FakeAdminBackend(),
    );
    expect(find.text('You are not in any group yet'), findsOneWidget);
  });
}
