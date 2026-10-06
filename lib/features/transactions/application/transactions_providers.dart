import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../../auth/application/session_controller.dart';
import '../../dashboard/application/dashboard_providers.dart';
import '../../groups/application/groups_providers.dart';
import '../../groups/domain/group.dart';
import '../data/transactions_repository.dart';
import '../domain/transaction.dart';

/// Active groups the user can record transactions in (RLS already limits a
/// member to their own active groups; the Super Admin sees all).
final transactionGroupsProvider = FutureProvider.autoDispose<List<Group>>((
  ref,
) async {
  final groups = await ref.watch(groupsListProvider.future);
  return groups.where((g) => g.isActive).toList(growable: false);
});

/// Last group used in the transaction form, remembered on this device.
class LastUsedGroup extends Notifier<String?> {
  static const _key = 'tx.last_group_id';

  @override
  String? build() {
    try {
      return ref.watch(sharedPreferencesProvider).getString(_key);
    } catch (_) {
      return null; // prefs not available (tests)
    }
  }

  void set(String groupId) {
    state = groupId;
    try {
      ref.read(sharedPreferencesProvider).setString(_key, groupId);
    } catch (_) {}
  }
}

final lastUsedGroupProvider = NotifierProvider<LastUsedGroup, String?>(
  LastUsedGroup.new,
);

typedef CategoryKey = ({String groupId, TransactionType type});

final categoriesProvider = FutureProvider.autoDispose
    .family<List<Category>, CategoryKey>(
      (ref, key) => ref
          .watch(categoriesRepositoryProvider)
          .list(key.groupId, type: key.type),
    );

/// All categories of a group (both types, including deleted) for management.
final allCategoriesProvider = FutureProvider.autoDispose
    .family<List<Category>, String>(
      (ref, groupId) => ref
          .watch(categoriesRepositoryProvider)
          .list(groupId, includeInactive: true),
    );

/// Whether the viewer may edit/delete ANY transaction of [groupId] (that
/// group's Group Admin or the Super Admin). Members may also edit their own
/// entries: see [TransactionHistory.canEdit]. UX only.
final canManageTransactionsProvider = Provider.autoDispose.family<bool, String>(
  (ref, groupId) {
    final ctx = ref.watch(currentUserContextProvider);
    if (ctx == null) return false;
    return ctx.profile.isSuperAdmin || ctx.isGroupAdminOf(groupId);
  },
);

class TransactionListState {
  const TransactionListState({
    required this.items,
    required this.hasMore,
    this.loadingMore = false,
    this.loadMoreError,
    this.fromCache = false,
  });

  final List<Transaction> items;
  final bool hasMore;
  final bool loadingMore;
  final Object? loadMoreError;

  /// The first page came from the device because the server was unreachable.
  final bool fromCache;

  TransactionListState copyWith({
    List<Transaction>? items,
    bool? hasMore,
    bool? loadingMore,
    Object? Function()? loadMoreError,
  }) => TransactionListState(
    items: items ?? this.items,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreError: loadMoreError != null ? loadMoreError() : this.loadMoreError,
    fromCache: fromCache,
  );
}

/// Keyset-paginated list for one filter. Pages are loaded on demand only.
class TransactionListController extends AsyncNotifier<TransactionListState> {
  TransactionListController(this.filter);

  final TransactionFilter filter;
  static const pageSize = 30;

  @override
  Future<TransactionListState> build() async {
    final page = await ref
        .watch(transactionsRepositoryProvider)
        .list(filter, limit: pageSize);
    return TransactionListState(
      items: page.items,
      hasMore: page.hasMore,
      fromCache: page.fromCache,
    );
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) return;
    if (current.items.isEmpty) return;
    state = AsyncData(
      current.copyWith(loadingMore: true, loadMoreError: () => null),
    );
    try {
      final page = await ref
          .read(transactionsRepositoryProvider)
          .list(
            filter,
            after: TransactionCursor.after(current.items.last),
            limit: pageSize,
          );
      state = AsyncData(
        current.copyWith(
          items: [...current.items, ...page.items],
          hasMore: page.hasMore,
          loadingMore: false,
        ),
      );
    } catch (e) {
      state = AsyncData(
        current.copyWith(loadingMore: false, loadMoreError: () => e),
      );
    }
  }
}

final transactionListProvider = AsyncNotifierProvider.autoDispose
    .family<TransactionListController, TransactionListState, TransactionFilter>(
      TransactionListController.new,
    );

/// Server-side total for a list header.
final transactionTotalProvider = FutureProvider.autoDispose
    .family<int, TransactionFilter>(
      (ref, filter) => ref.watch(transactionsRepositoryProvider).total(filter),
    );

/// Who added an entry and who last edited it (detail sheet).
final transactionHistoryProvider = FutureProvider.autoDispose
    .family<TransactionHistory, String>(
      (ref, id) => ref.watch(transactionsRepositoryProvider).history(id),
    );

/// Refresh every list/total after a create/edit/delete.
void invalidateTransactions(WidgetRef ref) {
  ref
    ..invalidate(transactionListProvider)
    ..invalidate(transactionTotalProvider)
    ..invalidate(transactionHistoryProvider)
    ..invalidate(dashboardProvider)
    ..invalidate(groupBalancesProvider);
}
