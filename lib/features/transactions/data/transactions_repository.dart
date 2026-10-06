import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/errors/error_mapper.dart';
import '../../../core/network/reachability.dart';
import '../../../core/network/supabase_providers.dart';
import '../../../core/sync/cache_store.dart';
import '../../../core/sync/outbox_processor.dart';
import '../../../core/sync/sync_bootstrap.dart';
import '../../../core/sync/sync_engine.dart';
import '../../../core/sync/transactions_local_data_source.dart';
import '../../../core/utils/ist_date.dart';
import '../../../core/utils/money.dart';
import '../domain/transaction.dart' as domain;
import '../domain/transaction.dart' show TransactionType;

/// Ledger access. Today this talks to Supabase directly; Phases 9–10 put a
/// local (Drift) data source + outbox behind the same interface, which is why
/// the client generates the transaction id. Throws [AppFailure]s.
abstract interface class TransactionsRepository {
  /// Creates a transaction (idempotent on [id]; a new id is generated when
  /// omitted). Returns the stored row.
  Future<domain.Transaction> add(domain.TransactionDraft draft, {String? id});

  Future<domain.Transaction> update(
    String id,
    domain.TransactionDraft draft, {
    required int expectedVersion,
  });

  Future<void> delete(String id, {required int expectedVersion});

  Future<domain.TransactionPage> list(
    domain.TransactionFilter filter, {
    domain.TransactionCursor? after,
    int limit,
  });

  /// Server-side total for the filter's group/type/date range (and category
  /// when set). Amount bounds are ignored.
  Future<int> total(domain.TransactionFilter filter);

  /// One transaction by id, telling a deleted entry apart from one the user
  /// can't see. Throws NetworkFailure when offline and not cached.
  Future<domain.TransactionLookup> findById(String id);

  /// Who added the entry and who last edited it. Needs a connection.
  Future<domain.TransactionHistory> history(String id);
}

class SupabaseTransactionsRepository implements TransactionsRepository {
  SupabaseTransactionsRepository(this._client);

  final SupabaseClient _client;
  static const _uuid = Uuid();

  @override
  Future<domain.TransactionLookup> findById(String id) => _guard(() async {
    // RLS: rows of groups this user can see, including soft-deleted ones.
    final row = await _client.rest
        .from('transactions')
        .select()
        .eq('id', id)
        .maybeSingle();
    if (row != null) {
      return domain.TransactionFound(domain.Transaction.fromJson(row));
    }
    // Deleted entries are gone from the table (hard delete); the server keeps
    // a short-lived tombstone so we can still say "has been deleted".
    final gone = await _client.rpc<Map<String, dynamic>?>(
      'get_deleted_transaction',
      params: {'p_id': id},
    );
    return gone == null
        ? const domain.TransactionUnavailable()
        : domain.TransactionDeleted(
            TransactionType.fromWire(gone['type'] as String),
          );
  });

  @override
  Future<domain.TransactionHistory> history(String id) => _guard(() async {
    final json = await _client.rpc<Map<String, dynamic>>(
      'get_transaction_history',
      params: {'p_transaction_id': id},
    );
    return domain.TransactionHistory.fromJson(json);
  });

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e, st) {
      throw mapError(e, st);
    }
  }

  Map<String, Object?> _fields(domain.TransactionDraft d) => {
    'p_type': d.type.wire,
    'p_amount': Money.toNumericString(d.amountPaise),
    'p_category': d.category,
    'p_description': d.description,
    'p_transaction_date': IstDate.toIsoDate(d.date),
  };

  @override
  Future<domain.Transaction> add(domain.TransactionDraft draft, {String? id}) =>
      sendCreate({
        'p_id': id ?? _uuid.v4(),
        'p_group_id': draft.groupId,
        ..._fields(draft),
      });

  /// Sends a queued create (outbox payload = RPC params). Idempotent on p_id.
  Future<domain.Transaction> sendCreate(Map<String, Object?> payload) =>
      _guard(() async {
        final result = await _client.rpc<Map<String, dynamic>>(
          'upsert_transaction',
          params: payload,
        );
        return domain.Transaction.fromJson(
          (result['transaction'] as Map).cast<String, dynamic>(),
        );
      });

  @override
  Future<domain.Transaction> update(
    String id,
    domain.TransactionDraft draft, {
    required int expectedVersion,
  }) => _guard(() async {
    final row = await _client.rpc<Map<String, dynamic>>(
      'update_transaction',
      params: {
        'p_id': id,
        ..._fields(draft),
        'p_expected_version': expectedVersion,
      },
    );
    return domain.Transaction.fromJson(row);
  });

  @override
  Future<void> delete(String id, {required int expectedVersion}) => _guard(
    () => _client.rpc<dynamic>(
      'delete_transaction',
      params: {'p_id': id, 'p_expected_version': expectedVersion},
    ),
  );

  @override
  Future<domain.TransactionPage> list(
    domain.TransactionFilter filter, {
    domain.TransactionCursor? after,
    int limit = 30,
  }) => _guard(() async {
    // Ask for one extra row to know whether another page exists.
    final rows = await _client.rpc<List<dynamic>>(
      'list_transactions',
      params: {
        'p_group_id': filter.groupId,
        'p_type': filter.type?.wire,
        'p_from': filter.from == null ? null : IstDate.toIsoDate(filter.from!),
        'p_to': filter.to == null ? null : IstDate.toIsoDate(filter.to!),
        'p_category': filter.category,
        'p_min_amount': filter.minPaise == null
            ? null
            : Money.toNumericString(filter.minPaise!),
        'p_max_amount': filter.maxPaise == null
            ? null
            : Money.toNumericString(filter.maxPaise!),
        'p_cursor_date': after == null ? null : IstDate.toIsoDate(after.date),
        'p_cursor_created_at': after?.createdAt.toUtc().toIso8601String(),
        'p_cursor_id': after?.id,
        'p_limit': limit + 1,
      },
    );
    final items = [
      for (final r in rows)
        domain.Transaction.fromJson((r as Map).cast<String, dynamic>()),
    ];
    final hasMore = items.length > limit;
    return domain.TransactionPage(
      hasMore ? items.sublist(0, limit) : items,
      hasMore: hasMore,
    );
  });

  @override
  Future<int> total(domain.TransactionFilter filter) => _guard(() async {
    final rows = await _client.rpc<List<dynamic>>(
      'get_category_breakdown',
      params: {
        'p_group_id': filter.groupId,
        'p_type': (filter.type ?? TransactionType.expense).wire,
        'p_from': IstDate.toIsoDate(filter.from ?? DateTime.utc(2000)),
        'p_to': IstDate.toIsoDate(filter.to ?? IstDate.today()),
      },
    );
    var sum = 0;
    for (final r in rows) {
      final row = (r as Map).cast<String, dynamic>();
      if (filter.category != null &&
          (row['category'] as String).toLowerCase() !=
              filter.category!.toLowerCase()) {
        continue;
      }
      sum += Money.fromNumeric(row['total'] as Object);
    }
    return sum;
  });
}

/// Per-group categories (owner decision 8). Throws [AppFailure]s.
abstract interface class CategoriesRepository {
  Future<List<domain.Category>> list(
    String groupId, {
    TransactionType? type,
    bool includeInactive,
  });

  Future<void> rename(String categoryId, String name);

  Future<void> delete(String categoryId);
}

class SupabaseCategoriesRepository implements CategoriesRepository {
  SupabaseCategoriesRepository(this._client, [this._cache]);

  final SupabaseClient _client;
  final CacheStore? _cache;

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e, st) {
      throw mapError(e, st);
    }
  }

  @override
  Future<List<domain.Category>> list(
    String groupId, {
    TransactionType? type,
    bool includeInactive = false,
  }) => fetchWithCache(
    _cache,
    'categories.$groupId.${type?.wire ?? 'ALL'}.$includeInactive',
    () {
      var query = _client.rest
          .from('group_categories')
          .select('id, group_id, type, name, is_active, sort_order')
          .eq('group_id', groupId);
      if (type != null) query = query.eq('type', type.wire);
      if (!includeInactive) query = query.eq('is_active', true);
      return query
          .order('sort_order', ascending: true)
          .order('name', ascending: true);
    },
    (raw, _) => [
      for (final r in raw! as List) domain.Category.fromJson((r as Map).cast()),
    ],
  );

  @override
  Future<void> rename(String categoryId, String name) => _guard(
    () => _client.rpc<dynamic>(
      'rename_group_category',
      params: {'p_category_id': categoryId, 'p_name': name},
    ),
  );

  @override
  Future<void> delete(String categoryId) => _guard(
    () => _client.rpc<dynamic>(
      'delete_group_category',
      params: {'p_category_id': categoryId},
    ),
  );
}

final remoteTransactionsRepositoryProvider =
    Provider<SupabaseTransactionsRepository>(
      (ref) =>
          SupabaseTransactionsRepository(ref.watch(supabaseClientProvider)),
    );

final outboxProcessorProvider = Provider<OutboxProcessor>((ref) {
  final processor = OutboxProcessor(
    ref.watch(appDatabaseProvider),
    ref.watch(transactionsLocalDataSourceProvider),
    ref.watch(remoteTransactionsRepositoryProvider).sendCreate,
  );
  ref.onDispose(processor.dispose);
  return processor;
});

/// When to sync (triggers, reachability, backoff timer). One per app.
final syncEngineProvider = Provider<SyncEngine>((ref) {
  final engine = SyncEngine(
    ref.watch(outboxProcessorProvider),
    Reachability().check,
  );
  ref.onDispose(engine.dispose);
  return engine;
});

/// Writes on this device not yet accepted by the server (PENDING + FAILED).
final unsyncedCountProvider = StreamProvider<int>(
  (ref) => ref.watch(localSyncEnabledProvider)
      ? ref.watch(transactionsLocalDataSourceProvider).watchUnsyncedCount()
      : Stream.value(0),
);

/// What the app uses: offline-first over the remote repository.
final transactionsRepositoryProvider = Provider<TransactionsRepository>(
  (ref) => OfflineFirstTransactionsRepository(
    ref.watch(remoteTransactionsRepositoryProvider),
    ref.watch(transactionsLocalDataSourceProvider),
    ref.watch(outboxProcessorProvider),
    afterSendAttempt: () => ref.read(syncEngineProvider).reschedule(),
  ),
);

/// Offline-first ledger (spec §20): writes go to SQLite + outbox first and the
/// UI never waits on the network to record a transaction; reads come from the
/// server when reachable (and are cached), otherwise from SQLite.
class OfflineFirstTransactionsRepository implements TransactionsRepository {
  OfflineFirstTransactionsRepository(
    this._remote,
    this._local,
    this._outbox, {
    this.afterSendAttempt,
  });

  final TransactionsRepository _remote;
  final TransactionsLocalDataSource _local;
  final OutboxProcessor _outbox;
  static const _uuid = Uuid();

  /// Lets the sync engine schedule a retry if the immediate send failed.
  final Future<void> Function()? afterSendAttempt;

  /// How long [add] waits for the immediate sync before reporting "pending".
  static const syncWait = Duration(seconds: 8);

  @override
  Future<domain.Transaction> add(
    domain.TransactionDraft draft, {
    String? id,
  }) async {
    final category = draft.category?.trim();
    final description = draft.description?.trim();
    final local = await _local.insertPending(
      domain.Transaction(
        id: id ?? _uuid.v4(),
        groupId: draft.groupId,
        type: draft.type,
        amountPaise: draft.amountPaise,
        category: category == null || category.isEmpty ? null : category,
        description: description == null || description.isEmpty
            ? null
            : description,
        date: draft.date,
      ),
    );
    // Try right away; offline it simply stays queued until a sync trigger.
    final sent = await _outbox
        .flush(force: true)
        .timeout(syncWait, onTimeout: () => const FlushResult(offline: true));
    // A server error → schedule the backoff retry.
    if (!sent.offline) await afterSendAttempt?.call();
    return (await _local.byId(local.id)) ?? local;
  }

  @override
  Future<domain.Transaction> update(
    String id,
    domain.TransactionDraft draft, {
    required int expectedVersion,
  }) async {
    try {
      final row = await _remote.update(
        id,
        draft,
        expectedVersion: expectedVersion,
      );
      await _local.markSynced(row);
      return row;
    } on NetworkFailure {
      throw const NetworkFailure(
        'You are offline. Editing needs an internet connection.',
      );
    }
  }

  @override
  Future<void> delete(String id, {required int expectedVersion}) async {
    final local = await _local.byId(id);
    if (local != null && local.syncState != domain.SyncState.synced) {
      // Never reached the server: just drop it from the queue.
      await _outbox.discard(id);
      return;
    }
    try {
      await _remote.delete(id, expectedVersion: expectedVersion);
      await _local.remove(id);
    } on NetworkFailure {
      throw const NetworkFailure(
        'You are offline. Deleting needs an internet connection.',
      );
    }
  }

  @override
  Future<domain.TransactionPage> list(
    domain.TransactionFilter filter, {
    domain.TransactionCursor? after,
    int limit = 30,
  }) async {
    final domain.TransactionPage page;
    try {
      page = await _remote.list(filter, after: after, limit: limit);
    } on NetworkFailure {
      return _local.query(filter, after: after, limit: limit);
    }
    await _local.upsertFromServer(page.items);
    await _local.reconcileWindow(
      filter,
      after: after,
      lastInPage: page.items.isEmpty ? null : page.items.last,
      hasMore: page.hasMore,
      serverIds: {for (final t in page.items) t.id},
    );
    if (after != null) return page;
    // First page: show this device's not-yet-synced entries too.
    final ids = {for (final t in page.items) t.id};
    final unsynced = [
      for (final t in await _local.unsynced(filter))
        if (!ids.contains(t.id)) t,
    ];
    if (unsynced.isEmpty) return page;
    final merged = [...unsynced, ...page.items]
      ..sort((a, b) {
        final d = b.date.compareTo(a.date);
        if (d != 0) return d;
        return (b.createdAt ?? DateTime(0)).compareTo(
          a.createdAt ?? DateTime(0),
        );
      });
    return domain.TransactionPage(merged, hasMore: page.hasMore);
  }

  @override
  Future<domain.TransactionLookup> findById(String id) async {
    // This device's own unsynced entry isn't on the server yet.
    final local = await _local.byId(id);
    if (local != null && !local.isSynced) return domain.TransactionFound(local);
    try {
      return await _remote.findById(id);
    } on NetworkFailure {
      if (local != null) return domain.TransactionFound(local);
      rethrow;
    }
  }

  @override
  Future<domain.TransactionHistory> history(String id) => _remote.history(id);

  @override
  Future<int> total(domain.TransactionFilter filter) async {
    try {
      final server = await _remote.total(filter);
      // Include entries this device recorded that haven't synced yet.
      final pending = [
        for (final t in await _local.unsynced(filter))
          if (t.isPending) t.amountPaise,
      ];
      return server + pending.fold<int>(0, (a, b) => a + b);
    } on NetworkFailure {
      return _local.total(filter);
    }
  }
}

final categoriesRepositoryProvider = Provider<CategoriesRepository>(
  (ref) => SupabaseCategoriesRepository(
    ref.watch(supabaseClientProvider),
    ref.watch(cacheStoreProvider),
  ),
);
