import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/sync/sync_banner.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/ist_date.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/async_value_view.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../routing/routes.dart';
import '../../auth/application/session_controller.dart';
import '../../groups/application/groups_providers.dart';
import '../../groups/domain/group.dart';
import '../application/transactions_providers.dart';
import '../data/transactions_repository.dart';
import '../domain/transaction.dart';

/// Filterable, paginated transaction list.
/// [type] null = both income and expense (group ledger view).
/// [fixedGroupId] set = one group only (no group filter).
class TransactionsView extends ConsumerStatefulWidget {
  const TransactionsView({super.key, this.type, this.fixedGroupId});

  final TransactionType? type;
  final String? fixedGroupId;

  @override
  ConsumerState<TransactionsView> createState() => _TransactionsViewState();
}

class _TransactionsViewState extends ConsumerState<TransactionsView> {
  /// First day of the selected month (UTC date), or null for "All time".
  DateTime? _month = _monthOf(IstDate.today());
  String? _groupId;
  String? _category;
  int? _minPaise;
  int? _maxPaise;

  static DateTime _monthOf(DateTime d) => DateTime.utc(d.year, d.month);

  TransactionFilter get _filter {
    final month = _month;
    return TransactionFilter(
      groupId: widget.fixedGroupId ?? _groupId,
      type: widget.type,
      from: month,
      to: month == null
          ? null
          : DateTime.utc(
              month.year,
              month.month + 1,
            ).subtract(const Duration(days: 1)),
      category: _category,
      minPaise: _minPaise,
      maxPaise: _maxPaise,
    );
  }

  void _shiftMonth(int delta) {
    final m = _month ?? _monthOf(IstDate.today());
    setState(() => _month = DateTime.utc(m.year, m.month + delta));
  }

  Future<void> _openFilters() async {
    final result = await showModalBottomSheet<_FilterResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      useRootNavigator: true,
      builder: (_) => _FilterSheet(
        type: widget.type,
        showGroup: widget.fixedGroupId == null,
        groupId: _groupId,
        category: _category,
        minPaise: _minPaise,
        maxPaise: _maxPaise,
        allTime: _month == null,
      ),
    );
    if (result == null) return;
    setState(() {
      _groupId = result.groupId;
      _category = result.category;
      _minPaise = result.minPaise;
      _maxPaise = result.maxPaise;
      if (result.allTime) {
        _month = null;
      } else {
        _month ??= _monthOf(IstDate.today());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final filter = _filter;
    final list = ref.watch(transactionListProvider(filter));
    final groupNames = <String, String>{
      for (final g in ref.watch(groupsListProvider).value ?? const <Group>[])
        g.id: g.name,
    };
    final showGroupName =
        widget.fixedGroupId == null &&
        _groupId == null &&
        groupNames.length > 1;
    final thisMonth = _monthOf(IstDate.today());

    return RefreshIndicator(
      onRefresh: () async => invalidateTransactions(ref),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < 400) {
            ref.read(transactionListProvider(filter).notifier).loadMore();
          }
          return false;
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SyncBanner(offline: list.value?.fromCache ?? false),
                    _MonthSwitcher(
                      month: _month,
                      canGoForward:
                          _month != null && _month!.isBefore(thisMonth),
                      onPrev: () => _shiftMonth(-1),
                      onNext: () => _shiftMonth(1),
                      onTapAllTime: () => setState(
                        () => _month = _month == null ? thisMonth : null,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _Totals(filter: filter),
                    const SizedBox(height: AppSpacing.md),
                    _FilterChips(
                      groupName: _groupId == null ? null : groupNames[_groupId],
                      showGroup:
                          widget.fixedGroupId == null && groupNames.length > 1,
                      category: _category,
                      minPaise: _minPaise,
                      maxPaise: _maxPaise,
                      onOpen: _openFilters,
                      onClear: () => setState(() {
                        _groupId = null;
                        _category = null;
                        _minPaise = null;
                        _maxPaise = null;
                      }),
                    ),
                  ],
                ),
              ),
            ),
            ...switch (list) {
              AsyncValue(hasValue: true, :final value?) =>
                value.items.isEmpty
                    ? [
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: EmptyState(
                            icon: Icons.receipt_long_outlined,
                            title: 'No transactions',
                            message: _month == null
                                ? 'Nothing recorded yet. Tap + to add one.'
                                : 'Nothing recorded for this month.',
                          ),
                        ),
                      ]
                    : _listSlivers(value, showGroupName, groupNames),
              _ => [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: AsyncValueView(
                    value: list,
                    onRetry: () =>
                        ref.invalidate(transactionListProvider(filter)),
                    data: (_) => const SizedBox.shrink(),
                  ),
                ),
              ],
            },
          ],
        ),
      ),
    );
  }

  List<Widget> _listSlivers(
    TransactionListState state,
    bool showGroupName,
    Map<String, String> groupNames,
  ) {
    // Flatten into day headers + rows.
    final rows = <Object>[];
    DateTime? day;
    for (final t in state.items) {
      if (t.date != day) {
        day = t.date;
        rows.add(day);
      }
      rows.add(t);
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        sliver: SliverList.builder(
          itemCount: rows.length,
          itemBuilder: (context, i) {
            final row = rows[i];
            if (row is DateTime) return _DayHeader(date: row);
            final t = row as Transaction;
            return TransactionTile(
              transaction: t,
              groupName: showGroupName ? groupNames[t.groupId] : null,
              onTap: () => showTransactionDetails(
                context,
                t,
                groupName: groupNames[t.groupId],
              ),
            );
          },
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Center(
            child: state.loadingMore
                ? const CircularProgressIndicator()
                : state.loadMoreError != null
                ? TextButton(
                    onPressed: () => ref
                        .read(transactionListProvider(_filter).notifier)
                        .loadMore(),
                    child: const Text('Couldn\'t load more. Try again'),
                  )
                : const SizedBox(height: 56),
          ),
        ),
      ),
    ];
  }
}

class _MonthSwitcher extends StatelessWidget {
  const _MonthSwitcher({
    required this.month,
    required this.canGoForward,
    required this.onPrev,
    required this.onNext,
    required this.onTapAllTime,
  });

  final DateTime? month;
  final bool canGoForward;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onTapAllTime;

  @override
  Widget build(BuildContext context) {
    final label = month == null
        ? 'All time'
        : DateFormat('MMMM yyyy').format(month!);
    return Row(
      children: [
        IconButton(
          tooltip: 'Previous month',
          onPressed: month == null ? null : onPrev,
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Expanded(
          child: TextButton(
            onPressed: onTapAllTime,
            child: Text(label, style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
        IconButton(
          tooltip: 'Next month',
          onPressed: canGoForward ? onNext : null,
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ],
    );
  }
}

class _Totals extends ConsumerWidget {
  const _Totals({required this.filter});

  final TransactionFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final types = filter.type == null ? TransactionType.values : [filter.type!];
    return Row(
      children: [
        for (final (i, type) in types.indexed) ...[
          if (i > 0) const SizedBox(width: AppSpacing.md),
          Expanded(
            child: _TotalCard(
              type: type,
              filter: TransactionFilter(
                groupId: filter.groupId,
                type: type,
                from: filter.from,
                to: filter.to,
                category: filter.category,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _TotalCard extends ConsumerWidget {
  const _TotalCard({required this.type, required this.filter});

  final TransactionType type;
  final TransactionFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final total = ref.watch(transactionTotalProvider(filter));
    final color = type == TransactionType.expense
        ? AppColors.expense
        : AppColors.income;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              type == TransactionType.expense
                  ? 'Total spent'
                  : 'Total received',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              total.hasValue ? Money.format(total.requireValue) : '—',
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterChips extends StatelessWidget {
  const _FilterChips({
    required this.groupName,
    required this.showGroup,
    required this.category,
    required this.minPaise,
    required this.maxPaise,
    required this.onOpen,
    required this.onClear,
  });

  final String? groupName;
  final bool showGroup;
  final String? category;
  final int? minPaise;
  final int? maxPaise;
  final VoidCallback onOpen;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final active =
        groupName != null ||
        category != null ||
        minPaise != null ||
        maxPaise != null;
    String? amount;
    if (minPaise != null || maxPaise != null) {
      amount = [
        if (minPaise != null) '≥ ${Money.format(minPaise!)}',
        if (maxPaise != null) '≤ ${Money.format(maxPaise!)}',
      ].join(' ');
    }
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ActionChip(
          avatar: const Icon(Icons.tune_rounded, size: 18),
          label: const Text('Filters'),
          onPressed: onOpen,
        ),
        if (showGroup && groupName != null) Chip(label: Text(groupName!)),
        if (category != null) Chip(label: Text(category!)),
        if (amount != null) Chip(label: Text(amount)),
        if (active) TextButton(onPressed: onClear, child: const Text('Clear')),
      ],
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final today = IstDate.today();
    final label = date == today
        ? 'Today'
        : date == today.subtract(const Duration(days: 1))
        ? 'Yesterday'
        : DateFormat('EEE, d MMM yyyy').format(date);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg, bottom: AppSpacing.sm),
      child: Text(label, style: Theme.of(context).textTheme.labelLarge),
    );
  }
}

class TransactionTile extends StatelessWidget {
  const TransactionTile({
    super.key,
    required this.transaction,
    this.groupName,
    this.onTap,
  });

  final Transaction transaction;
  final String? groupName;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = transaction;
    final color = t.isExpense ? AppColors.expense : AppColors.income;
    final subtitle = [
      if (t.description != null && t.description!.isNotEmpty) t.description!,
      ?groupName,
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        minTileHeight: 64,
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.14),
          child: Icon(
            t.isExpense
                ? Icons.arrow_upward_rounded
                : Icons.arrow_downward_rounded,
            color: color,
            size: 20,
          ),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                t.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!t.isSynced) ...[
              const SizedBox(width: AppSpacing.sm),
              _SyncBadge(failed: t.isFailed),
            ],
          ],
        ),
        subtitle: subtitle.isEmpty
            ? null
            : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Text(
          '${t.isExpense ? '−' : '+'}${Money.format(t.amountPaise)}',
          style: TextStyle(
            fontFamily: AppFonts.display,
            color: color,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
      ),
    );
  }
}

/// "Pending" (queued on this device) or "Not synced" (server rejected it).
class _SyncBadge extends StatelessWidget {
  const _SyncBadge({required this.failed});

  final bool failed;

  @override
  Widget build(BuildContext context) {
    final color = failed ? AppColors.expense : AppColors.warning;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          failed ? Icons.error_outline_rounded : Icons.schedule_rounded,
          size: 14,
          color: color,
        ),
        const SizedBox(width: 2),
        Text(
          failed ? 'Not synced' : 'Pending',
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

/// Details + (for that group's Group Admin / the Super Admin) edit and delete.
Future<void> showTransactionDetails(
  BuildContext context,
  Transaction t, {
  String? groupName,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    useRootNavigator: true,
    // Sized to its content (up to the safe area), scrolling if taller.
    isScrollControlled: true,
    builder: (_) =>
        _TransactionDetailSheet(transaction: t, groupName: groupName),
  );
}

class _TransactionDetailSheet extends ConsumerWidget {
  const _TransactionDetailSheet({required this.transaction, this.groupName});

  final Transaction transaction;
  final String? groupName;

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final t = transaction;
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete this ${t.type.label.toLowerCase()}?',
      message:
          '${Money.format(t.amountPaise)} · ${t.title} on '
          '${DateFormat('d MMM yyyy').format(t.date)} will be permanently '
          'deleted and removed from the group\'s balances. This can\'t be '
          'undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    final ok = await runAction(
      context,
      () => ref
          .read(transactionsRepositoryProvider)
          .delete(t.id, expectedVersion: t.syncVersion),
      successMessage: '${t.type.label} deleted',
    );
    if (ok) {
      invalidateTransactions(ref);
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _retry(BuildContext context, WidgetRef ref) async {
    final processor = ref.read(outboxProcessorProvider);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final result = await processor.retry(transaction.id);
    invalidateTransactions(ref);
    navigator.pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.offline
              ? 'Still offline. Will sync when the connection is back.'
              : result.failed > 0
              ? 'Still could not be synced'
              : '${transaction.type.label} synced',
        ),
      ),
    );
  }

  Future<void> _discard(BuildContext context, WidgetRef ref) async {
    final t = transaction;
    final confirmed = await showConfirmDialog(
      context,
      title: 'Discard this ${t.type.label.toLowerCase()}?',
      message:
          '${Money.format(t.amountPaise)} · ${t.title} never reached the '
          'server. It will be removed from this device.',
      confirmLabel: 'Discard',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    final ok = await runAction(
      context,
      () => ref.read(outboxProcessorProvider).discard(t.id),
      successMessage: '${t.type.label} discarded',
    );
    if (ok) {
      invalidateTransactions(ref);
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = transaction;
    // Unsynced rows exist only on this device: anyone can retry/discard
    // them, but they can't be edited until the server has them. Synced rows:
    // admins always; members only their own entries (the server decides,
    // via the history's canEdit, and enforces it on edit/delete).
    final canManage =
        t.isSynced &&
        (ref.watch(canManageTransactionsProvider(t.groupId)) ||
            (ref.watch(transactionHistoryProvider(t.id)).value?.canEdit ??
                false));
    final color = t.isExpense ? AppColors.expense : AppColors.income;
    final textTheme = Theme.of(context).textTheme;
    final bottom = MediaQuery.viewPaddingOf(context).bottom;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.lg + bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t.type.label, style: textTheme.bodyMedium),
          const SizedBox(height: AppSpacing.xs),
          Text(
            Money.format(t.amountPaise),
            style: textTheme.displaySmall?.copyWith(color: color),
          ),
          const SizedBox(height: AppSpacing.lg),
          _DetailRow(label: 'Category', value: t.title),
          if (t.description != null && t.description!.isNotEmpty)
            _DetailRow(label: 'Description', value: t.description!),
          _DetailRow(
            label: 'Date',
            value: DateFormat('EEEE, d MMMM yyyy').format(t.date),
          ),
          if (groupName != null) _DetailRow(label: 'Group', value: groupName!),
          if (t.isSynced)
            _HistoryRows(transactionId: t.id)
          else
            _DetailRow(
              label: 'Added by',
              value:
                  ref.watch(currentUserContextProvider)?.profile.name ?? 'You',
            ),
          if (!t.isSynced) ...[
            _DetailRow(
              label: 'Sync',
              value: t.isFailed
                  ? 'Not synced: ${t.syncError ?? 'rejected by the server'}'
                  : 'Saved on this device. Will sync when online.',
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('tx-retry'),
                    onPressed: () => _retry(context, ref),
                    icon: const Icon(Icons.sync_rounded),
                    label: Text(t.isFailed ? 'Retry' : 'Sync now'),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('tx-discard'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.expense,
                    ),
                    onPressed: () => _discard(context, ref),
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Discard'),
                  ),
                ),
              ],
            ),
          ],
          if (canManage) ...[
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      context.push(Routes.editTransaction, extra: t);
                    },
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Edit'),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.expense,
                    ),
                    onPressed: () => _delete(context, ref),
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Delete'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// "Added by" and, after an edit, "Edited by" (from the server's history).
class _HistoryRows extends ConsumerWidget {
  const _HistoryRows({required this.transactionId});

  final String transactionId;

  static String _who(HistoryEvent e) =>
      '${e.name ?? 'Deleted user'} · ${DateFormat('d MMM yyyy, h:mm a').format(e.at)}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(transactionHistoryProvider(transactionId));
    return history.when(
      loading: () => const _DetailRow(label: 'Added by', value: '…'),
      error: (e, _) => _DetailRow(
        label: 'Added by',
        value: e is NetworkFailure ? 'Available when online' : 'Unavailable',
      ),
      data: (h) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DetailRow(
            key: const Key('tx-added-by'),
            label: 'Added by',
            value: h.created == null ? 'Not recorded' : _who(h.created!),
          ),
          if (h.updated != null)
            _DetailRow(
              key: const Key('tx-edited-by'),
              label: 'Edited by',
              value: _who(h.updated!),
            ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 110, child: Text(label, style: textTheme.bodyMedium)),
          Expanded(child: Text(value, style: textTheme.bodyLarge)),
        ],
      ),
    );
  }
}

class _FilterResult {
  const _FilterResult({
    this.groupId,
    this.category,
    this.minPaise,
    this.maxPaise,
    this.allTime = false,
  });

  final String? groupId;
  final String? category;
  final int? minPaise;
  final int? maxPaise;
  final bool allTime;
}

class _FilterSheet extends ConsumerStatefulWidget {
  const _FilterSheet({
    required this.type,
    required this.showGroup,
    required this.groupId,
    required this.category,
    required this.minPaise,
    required this.maxPaise,
    required this.allTime,
  });

  final TransactionType? type;
  final bool showGroup;
  final String? groupId;
  final String? category;
  final int? minPaise;
  final int? maxPaise;
  final bool allTime;

  @override
  ConsumerState<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends ConsumerState<_FilterSheet> {
  late String? _groupId = widget.groupId;
  late final _category = TextEditingController(text: widget.category ?? '');
  late final _min = TextEditingController(
    text: widget.minPaise == null
        ? ''
        : Money.toNumericString(widget.minPaise!),
  );
  late final _max = TextEditingController(
    text: widget.maxPaise == null
        ? ''
        : Money.toNumericString(widget.maxPaise!),
  );
  late bool _allTime = widget.allTime;

  @override
  void dispose() {
    _category.dispose();
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(groupsListProvider).value ?? const [];
    final inset =
        MediaQuery.viewInsetsOf(context).bottom +
        MediaQuery.viewPaddingOf(context).bottom;
    final amountFormatter = FilteringTextInputFormatter.allow(
      RegExp(r'^\d{0,10}(\.\d{0,2})?'),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.lg + inset,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Filters', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.lg),
            if (widget.showGroup && groups.length > 1) ...[
              DropdownButtonFormField<String?>(
                initialValue: _groupId,
                isExpanded: true,
                dropdownColor: AppColors.elevated,
                decoration: const InputDecoration(labelText: 'Group'),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('All groups'),
                  ),
                  for (final g in groups)
                    DropdownMenuItem(value: g.id, child: Text(g.name)),
                ],
                onChanged: (v) => setState(() => _groupId = v),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            TextField(
              controller: _category,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Category',
                hintText: 'Any',
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _min,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [amountFormatter],
                    decoration: const InputDecoration(labelText: 'Min ₹'),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: TextField(
                    controller: _max,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [amountFormatter],
                    decoration: const InputDecoration(labelText: 'Max ₹'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('All time (instead of one month)'),
              value: _allTime,
              onChanged: (v) => setState(() => _allTime = v),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              onPressed: () {
                final category = _category.text.trim();
                Navigator.of(context).pop(
                  _FilterResult(
                    groupId: _groupId,
                    category: category.isEmpty ? null : category,
                    minPaise: Money.parseToPaise(_min.text),
                    maxPaise: Money.parseToPaise(_max.text),
                    allTime: _allTime,
                  ),
                );
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }
}
