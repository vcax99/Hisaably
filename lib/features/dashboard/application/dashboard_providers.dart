import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/dashboard_repository.dart';
import '../domain/dashboard.dart';

typedef DashboardKey = ({String? groupId, DateTime month});

final dashboardProvider = FutureProvider.autoDispose
    .family<DashboardData, DashboardKey>(
      (ref, key) => ref
          .watch(dashboardRepositoryProvider)
          .getDashboard(groupId: key.groupId, month: key.month),
    );

final adminOverviewProvider = FutureProvider.autoDispose<AdminOverview>(
  (ref) => ref.watch(dashboardRepositoryProvider).getAdminOverview(),
);

/// "By group" rows for the Dashboard's All-groups view.
final groupBalancesProvider = FutureProvider.autoDispose
    .family<List<GroupBalance>, DateTime>(
      (ref, month) =>
          ref.watch(dashboardRepositoryProvider).getGroupBalances(month: month),
    );
