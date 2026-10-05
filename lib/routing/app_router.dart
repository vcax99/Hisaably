import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/application/session_controller.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/auth/presentation/splash_screen.dart';
import '../features/dashboard/presentation/dashboard_screen.dart';
import '../features/expenses/presentation/expenses_screen.dart';
import '../features/groups/presentation/admin_groups_screen.dart';
import '../features/groups/presentation/group_detail_screen.dart';
import '../features/groups/presentation/groups_screen.dart';
import '../features/income/presentation/income_screen.dart';
import '../features/notifications/presentation/notifications_screen.dart';
import '../features/settings/presentation/more_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/transactions/domain/transaction.dart';
import '../features/transactions/presentation/categories_screen.dart';
import '../features/transactions/presentation/group_transactions_screen.dart';
import '../features/transactions/presentation/transaction_form_screen.dart';
import '../core/widgets/wave_background.dart';
import '../features/users/presentation/create_user_screen.dart';
import '../features/users/presentation/user_detail_screen.dart';
import '../features/users/presentation/users_screen.dart';
import 'app_shell.dart';
import 'routes.dart';
import 'session_redirect.dart';

const _memberTabs = [
  ShellTab(
    label: 'Dashboard',
    icon: Icons.space_dashboard_outlined,
    selectedIcon: Icons.space_dashboard_rounded,
  ),
  ShellTab(
    label: 'Expenses',
    icon: Icons.receipt_long_outlined,
    selectedIcon: Icons.receipt_long_rounded,
  ),
  ShellTab(
    label: 'Income',
    icon: Icons.savings_outlined,
    selectedIcon: Icons.savings_rounded,
  ),
  ShellTab(
    label: 'Groups',
    icon: Icons.groups_outlined,
    selectedIcon: Icons.groups_rounded,
  ),
];

const _adminTabs = [
  ShellTab(
    label: 'Dashboard',
    icon: Icons.space_dashboard_outlined,
    selectedIcon: Icons.space_dashboard_rounded,
  ),
  ShellTab(
    label: 'Groups',
    icon: Icons.groups_outlined,
    selectedIcon: Icons.groups_rounded,
  ),
  ShellTab(
    label: 'Users',
    icon: Icons.manage_accounts_outlined,
    selectedIcon: Icons.manage_accounts_rounded,
  ),
  ShellTab(
    label: 'More',
    icon: Icons.more_horiz_rounded,
    selectedIcon: Icons.more_horiz_rounded,
  ),
];

StatefulShellBranch _branch(
  String path,
  Widget screen, {
  List<RouteBase> children = const [],
}) => StatefulShellBranch(
  routes: [
    GoRoute(
      path: path,
      pageBuilder: (_, _) =>
          NoTransitionPage(child: WaveBackdrop(child: screen)),
      routes: children,
    ),
  ],
);

/// Group detail plus its ledger and categories (used in both shells).
GoRoute _groupDetailRoute() => _route(
  ':groupId',
  (state) => GroupDetailScreen(groupId: state.pathParameters['groupId']!),
  routes: [
    _route(
      'transactions',
      (state) =>
          GroupTransactionsScreen(groupId: state.pathParameters['groupId']!),
    ),
    _route(
      'categories',
      (state) => CategoriesScreen(groupId: state.pathParameters['groupId']!),
    ),
  ],
);

/// Every page sits on the app backdrop (near-black + animated waves). Each
/// page owns an opaque one, so transitions never show the page below.
Page<void> _page(GoRouterState state, Widget child) => MaterialPage<void>(
  key: state.pageKey,
  child: WaveBackdrop(child: child),
);

GoRoute _route(
  String path,
  Widget Function(GoRouterState state) build, {
  List<RouteBase> routes = const [],
}) => GoRoute(
  path: path,
  pageBuilder: (_, state) => _page(state, build(state)),
  routes: routes,
);

/// Role-based routing: session → profile → role → status → memberships
/// (see [sessionRedirect]). Re-evaluated whenever the session changes.
final appRouterProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(sessionControllerProvider, (_, _) => refresh.value++);

  final router = GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: refresh,
    redirect: (_, state) => sessionRedirect(
      ref.read(sessionControllerProvider),
      state.matchedLocation,
    ),
    routes: [
      _route(Routes.splash, (_) => const SplashScreen()),
      _route(Routes.login, (_) => const LoginScreen()),
      _route(Routes.settings, (_) => const SettingsScreen()),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) =>
            AppShell(navigationShell: shell, tabs: _memberTabs),
        branches: [
          _branch(Routes.memberDashboard, const DashboardScreen()),
          _branch(Routes.memberExpenses, const ExpensesScreen()),
          _branch(Routes.memberIncome, const IncomeScreen()),
          _branch(
            Routes.memberGroups,
            const GroupsScreen(),
            children: [_groupDetailRoute()],
          ),
        ],
      ),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) =>
            AppShell(navigationShell: shell, tabs: _adminTabs),
        branches: [
          _branch(Routes.adminDashboard, const DashboardScreen()),
          _branch(
            Routes.adminGroups,
            const AdminGroupsScreen(),
            children: [_groupDetailRoute()],
          ),
          _branch(
            Routes.adminUsers,
            const UsersScreen(),
            children: [
              // 'new' must come before ':userId'.
              _route('new', (_) => const CreateUserScreen()),
              _route(
                ':userId',
                (state) =>
                    UserDetailScreen(userId: state.pathParameters['userId']!),
              ),
            ],
          ),
          _branch(Routes.adminMore, const MoreScreen()),
        ],
      ),
      _route(Routes.notifications, (_) => const NotificationsScreen()),
      _route(
        Routes.addTransactionPattern,
        (state) => TransactionFormScreen(
          type: state.pathParameters['type'] == 'income'
              ? TransactionType.income
              : TransactionType.expense,
          initialGroupId: state.uri.queryParameters['group'],
        ),
      ),
      _route(Routes.editTransaction, (state) {
        final existing = state.extra as Transaction?;
        return TransactionFormScreen(
          type: existing?.type ?? TransactionType.expense,
          existing: existing,
        );
      }),
    ],
  );
  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
  return router;
});
