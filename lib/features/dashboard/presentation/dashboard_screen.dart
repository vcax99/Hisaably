import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/sync/sync_banner.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/ist_date.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/async_value_view.dart';
import '../../../core/widgets/hisaably_logo.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../routing/routes.dart';
import '../../auth/application/session_controller.dart';
import '../../groups/domain/group.dart';
import '../../notifications/presentation/notification_bell.dart';
import '../../settings/presentation/account_button.dart';
import '../../transactions/application/transactions_providers.dart';
import '../../transactions/domain/transaction.dart';
import '../../transactions/presentation/transactions_view.dart';
import '../application/dashboard_providers.dart';
import '../domain/dashboard.dart';
import 'dashboard_charts.dart';

/// Dashboard for every role. Members/Group Admins pick one of their groups;
/// the Super Admin also gets user/group counts and an "All groups" view.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  static const _allGroups = '';

  DateTime _month = _monthOf(IstDate.today());

  /// Selected group id; [_allGroups] = all groups the viewer can see;
  /// null = not chosen yet (defaults applied in build).
  String? _selection;

  static DateTime _monthOf(DateTime d) => DateTime.utc(d.year, d.month);

  String _effectiveSelection(List<Group> groups, bool isSuperAdmin) {
    final ids = {for (final g in groups) g.id};
    final current = _selection;
    if (current != null && (current == _allGroups || ids.contains(current))) {
      return current;
    }
    // Several groups (or Super Admin) → the combined view first.
    return !isSuperAdmin && groups.length == 1 ? groups.single.id : _allGroups;
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(currentUserContextProvider)?.profile;
    final isSuperAdmin = profile?.isSuperAdmin ?? false;
    final groups = ref.watch(transactionGroupsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            HisaablyLogo(size: 30),
            SizedBox(width: AppSpacing.md),
            Text('Dashboard'),
          ],
        ),
        actions: const [NotificationBell(), AccountButton()],
      ),
      body: AsyncValueView(
        value: groups,
        onRetry: () => ref.invalidate(transactionGroupsProvider),
        data: (list) {
          if (list.isEmpty && !isSuperAdmin) {
            return const EmptyState(
              icon: Icons.groups_outlined,
              title: 'You are not in any group yet',
              message: 'Ask your administrator to add you to a group.',
            );
          }
          final selection = _effectiveSelection(list, isSuperAdmin);
          final groupId = selection == _allGroups ? null : selection;
          final key = (groupId: groupId, month: _month);
          return RefreshIndicator(
            onRefresh: () async {
              ref
                ..invalidate(dashboardProvider(key))
                ..invalidate(groupBalancesProvider);
              if (isSuperAdmin) ref.invalidate(adminOverviewProvider);
              await ref.read(dashboardProvider(key).future);
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.xxl,
              ),
              children: [
                _Welcome(name: profile?.name),
                // Super Admin: users/groups counts first, then the group
                // picker, the month switcher and the money.
                if (isSuperAdmin) ...[
                  const SizedBox(height: AppSpacing.md),
                  const _AdminOverviewRow(),
                ],
                const SizedBox(height: AppSpacing.md),
                _Selectors(
                  groups: list,
                  selection: selection,
                  allLabel: isSuperAdmin ? 'All groups' : 'All my groups',
                  showAll: isSuperAdmin || list.length > 1,
                  month: _month,
                  onGroup: (id) => setState(() => _selection = id),
                  onMonth: (m) => setState(() => _month = m),
                ),
                const SizedBox(height: AppSpacing.md),
                _DashboardBody(
                  dashboardKey: key,
                  groupNames: {for (final g in list) g.id: g.name},
                  isSuperAdmin: isSuperAdmin,
                  afterSummary:
                      groupId == null && (isSuperAdmin || list.length > 1)
                      ? _ByGroup(
                          month: _month,
                          onSelect: (id) => setState(() => _selection = id),
                        )
                      : null,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Selectors extends StatelessWidget {
  const _Selectors({
    required this.groups,
    required this.selection,
    required this.allLabel,
    required this.showAll,
    required this.month,
    required this.onGroup,
    required this.onMonth,
  });

  final List<Group> groups;
  final String selection;
  final String allLabel;
  final bool showAll;
  final DateTime month;
  final ValueChanged<String> onGroup;
  final ValueChanged<DateTime> onMonth;

  Widget _label(BuildContext context, String text) => Align(
    alignment: Alignment.centerLeft,
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleMedium,
    ),
  );

  DropdownMenuItem<String> _item(
    BuildContext context,
    String id,
    String text,
    IconData icon,
  ) {
    final selected = selection == id;
    return DropdownMenuItem(
      value: id,
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: selected ? AppColors.accent : AppColors.textSecondary,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? AppColors.accent : AppColors.textPrimary,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
          if (selected)
            const Icon(Icons.check_rounded, size: 18, color: AppColors.accent),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final thisMonth = DateTime.utc(IstDate.today().year, IstDate.today().month);
    final canGoForward = month.isBefore(thisMonth);
    return Column(
      children: [
        if (showAll || groups.length > 1)
          // Re-created when the selection changes elsewhere (By group list),
          // since a form field only reads its initial value once.
          KeyedSubtree(
            key: ValueKey('group-$selection'),
            child: DropdownButtonFormField<String>(
              key: const Key('group-dropdown'),
              initialValue: selection,
              isExpanded: true,
              dropdownColor: AppColors.elevated,
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              icon: const Icon(
                Icons.keyboard_arrow_down_rounded,
                color: AppColors.accent,
              ),
              decoration: InputDecoration(
                prefixIcon: Icon(
                  selection.isEmpty
                      ? Icons.layers_rounded
                      : Icons.groups_rounded,
                  color: AppColors.accent,
                ),
                filled: true,
                fillColor: AppColors.surface,
              ),
              selectedItemBuilder: (context) => [
                if (showAll) _label(context, allLabel),
                for (final g in groups) _label(context, g.name),
              ],
              items: [
                if (showAll) _item(context, '', allLabel, Icons.layers_rounded),
                for (final g in groups)
                  _item(context, g.id, g.name, Icons.groups_rounded),
              ],
              onChanged: (v) => onGroup(v ?? ''),
            ),
          )
        else if (groups.length == 1)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              groups.single.name,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        Row(
          children: [
            IconButton(
              tooltip: 'Previous month',
              onPressed: () =>
                  onMonth(DateTime.utc(month.year, month.month - 1)),
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            Expanded(
              child: Text(
                DateFormat('MMMM yyyy').format(month),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: 'Next month',
              onPressed: canGoForward
                  ? () => onMonth(DateTime.utc(month.year, month.month + 1))
                  : null,
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
      ],
    );
  }
}

class _AdminOverviewRow extends ConsumerWidget {
  const _AdminOverviewRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(adminOverviewProvider).value;
    String v(int? n) => n == null ? '—' : '$n';
    return Row(
      children: [
        Expanded(
          child: _StatTile(
            label: 'Users',
            value: v(overview?.usersTotal),
            detail: overview == null
                ? null
                : '${overview.usersActive} active · ${overview.usersDisabled} disabled',
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: _StatTile(
            label: 'Groups',
            value: v(overview?.groupsTotal),
            detail: overview == null ? null : '${overview.groupsActive} active',
          ),
        ),
      ],
    );
  }
}

/// "Welcome, Asha" in the accent green.
class _Welcome extends StatelessWidget {
  const _Welcome({required this.name});

  final String? name;

  static String firstName(String? name) {
    final parts = (name ?? '').trim().split(RegExp(r'\s+'));
    return parts.first;
  }

  @override
  Widget build(BuildContext context) {
    final first = firstName(name);
    return Text(
      first.isEmpty ? 'Welcome' : 'Welcome, $first',
      key: const Key('dashboard-welcome'),
      style: Theme.of(context).textTheme.headlineSmall
          ?.copyWith(color: AppColors.accent, fontWeight: FontWeight.w600),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _DashboardBody extends ConsumerWidget {
  const _DashboardBody({
    required this.dashboardKey,
    required this.groupNames,
    required this.isSuperAdmin,
    this.afterSummary,
  });

  final DashboardKey dashboardKey;
  final Map<String, String> groupNames;
  final bool isSuperAdmin;

  /// Shown under the balance tiles (the All-groups "By group" list).
  final Widget? afterSummary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(dashboardProvider(dashboardKey));
    return AsyncValueView(
      value: data,
      onRetry: () => ref.invalidate(dashboardProvider(dashboardKey)),
      data: (d) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SyncBanner(cachedAt: d.cachedAt),
          _DashboardContent(
            data: d,
            groupId: dashboardKey.groupId,
            groupNames: groupNames,
            isSuperAdmin: isSuperAdmin,
            afterSummary: afterSummary,
          ),
        ],
      ),
    );
  }
}

class _DashboardContent extends StatelessWidget {
  const _DashboardContent({
    required this.data,
    required this.groupId,
    required this.groupNames,
    required this.isSuperAdmin,
    this.afterSummary,
  });

  final Widget? afterSummary;

  final DashboardData data;
  final String? groupId;
  final Map<String, String> groupNames;
  final bool isSuperAdmin;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final summary = data.summary;
    final monthName = DateFormat('MMMM').format(data.month);
    final isCurrentMonth =
        data.month == DateTime.utc(IstDate.today().year, IstDate.today().month);
    final balance = data.currentBalancePaise;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Hero: balance.
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isCurrentMonth
                      ? (groupId == null && groupNames.length > 1
                            ? 'Combined balance'
                            : 'Current balance')
                      : 'Balance at end of $monthName',
                  style: textTheme.bodyMedium,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  Money.format(
                    isCurrentMonth ? balance : summary?.closingPaise ?? 0,
                  ),
                  style: textTheme.displaySmall?.copyWith(
                    color:
                        (isCurrentMonth
                                ? balance
                                : summary?.closingPaise ?? 0) <
                            0
                        ? AppColors.expense
                        : AppColors.textPrimary,
                  ),
                ),
                if (summary != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'Opening ${Money.format(summary.openingPaise)}  ·  '
                    'Closing ${Money.format(summary.closingPaise)}',
                    style: textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: _StatTile(
                label: '$monthName income',
                value: Money.format(summary?.incomePaise ?? 0),
                valueColor: AppColors.income,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: _StatTile(
                label: '$monthName expense',
                value: Money.format(summary?.expensePaise ?? 0),
                valueColor: AppColors.expense,
              ),
            ),
          ],
        ),
        if (afterSummary != null) ...[
          const SizedBox(height: AppSpacing.md),
          afterSummary!,
        ],
        const SizedBox(height: AppSpacing.md),
        _ChartCard(
          title: 'Spending by category',
          subtitle: monthName,
          child: data.expenseBreakdown.isEmpty
              ? const _NoData('No expenses this month')
              : ExpenseDonut(breakdown: data.expenseBreakdown),
        ),
        const SizedBox(height: AppSpacing.md),
        _ChartCard(
          title: 'Income vs expense',
          subtitle: 'Last 6 months',
          child: IncomeExpenseBars(trend: data.trend),
        ),
        const SizedBox(height: AppSpacing.md),
        _ChartCard(
          title: 'Balance trend',
          subtitle: 'Closing balance, last 6 months',
          child: BalanceTrendLine(trend: data.trend),
        ),
        const SizedBox(height: AppSpacing.md),
        _RecentCard(
          transactions: data.recent,
          groupNames: groupNames,
          showGroupName: groupId == null && groupNames.length > 1,
          seeAllPath: groupId == null
              ? (isSuperAdmin ? null : Routes.memberExpenses)
              : '${isSuperAdmin ? Routes.adminGroups : Routes.memberGroups}/$groupId/transactions',
        ),
      ],
    );
  }
}

/// All-groups view: each group's balance and this month's in/out; tap one
/// to open its own dashboard.
class _ByGroup extends ConsumerWidget {
  const _ByGroup({required this.month, required this.onSelect});

  final DateTime month;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(groupBalancesProvider(month));
    final textTheme = Theme.of(context).textTheme;
    final monthName = DateFormat('MMMM').format(month);
    return Card(
      key: const Key('by-group'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('By group', style: textTheme.titleMedium),
            Text(
              'Balance now · $monthName in / out',
              style: textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            ...switch (rows) {
              AsyncValue(hasValue: true, :final value?) when value.isEmpty => [
                const _NoData('No groups yet'),
              ],
              AsyncValue(hasValue: true, :final value?) => [
                for (final g in value)
                  InkWell(
                    borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                    onTap: () => onSelect(g.groupId),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.md,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        g.name,
                                        style: textTheme.titleMedium,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (!g.isActive) ...[
                                      const SizedBox(width: AppSpacing.sm),
                                      Text(
                                        'Disabled',
                                        style: textTheme.labelSmall,
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text:
                                            '+${Money.format(g.monthIncomePaise)}',
                                        style: const TextStyle(
                                          color: AppColors.income,
                                        ),
                                      ),
                                      const TextSpan(text: '  ·  '),
                                      TextSpan(
                                        text:
                                            '−${Money.format(g.monthExpensePaise)}',
                                        style: const TextStyle(
                                          color: AppColors.expense,
                                        ),
                                      ),
                                    ],
                                  ),
                                  style: textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          Text(
                            Money.format(g.currentBalancePaise),
                            style: textTheme.titleMedium,
                          ),
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: AppColors.textMuted,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
              AsyncValue(hasError: true) => [
                const _NoData('Couldn\'t load the groups'),
              ],
              _ => [
                const Padding(
                  padding: EdgeInsets.all(AppSpacing.lg),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
            },
          ],
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    this.detail,
    this.valueColor,
  });

  final String label;
  final String value;
  final String? detail;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: textTheme.bodyMedium, maxLines: 1),
            const SizedBox(height: AppSpacing.xs),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: textTheme.headlineSmall?.copyWith(color: valueColor),
              ),
            ),
            if (detail != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(detail!, style: textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: textTheme.titleMedium),
            Text(subtitle, style: textTheme.bodySmall),
            const SizedBox(height: AppSpacing.lg),
            child,
          ],
        ),
      ),
    );
  }
}

class _NoData extends StatelessWidget {
  const _NoData(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
    child: Text(
      message,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodyMedium,
    ),
  );
}

class _RecentCard extends StatelessWidget {
  const _RecentCard({
    required this.transactions,
    required this.groupNames,
    required this.showGroupName,
    required this.seeAllPath,
  });

  final List<Transaction> transactions;
  final Map<String, String> groupNames;
  final bool showGroupName;
  final String? seeAllPath;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Recent transactions',
                    style: textTheme.titleMedium,
                  ),
                ),
                if (seeAllPath != null && transactions.isNotEmpty)
                  TextButton(
                    onPressed: () => context.push(seeAllPath!),
                    child: const Text('See all'),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (transactions.isEmpty)
              const _NoData('Nothing recorded yet. Tap + to add one.')
            else
              for (final t in transactions)
                TransactionTile(
                  transaction: t,
                  groupName: showGroupName ? groupNames[t.groupId] : null,
                  onTap: () => showTransactionDetails(
                    context,
                    t,
                    groupName: groupNames[t.groupId],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
