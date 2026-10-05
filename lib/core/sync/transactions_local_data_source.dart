import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/transactions/domain/transaction.dart';
import '../database/app_database.dart';
import '../utils/ist_date.dart';
import '../utils/money.dart';

/// Local (Drift) side of the ledger: cached server rows plus queued writes.
class TransactionsLocalDataSource {
  TransactionsLocalDataSource(this._db);

  final AppDatabase _db;

  // ---------------------------------------------------------------- mapping
  static Transaction toDomain(LocalTransaction r) => Transaction(
    id: r.id,
    groupId: r.groupId,
    type: TransactionType.fromWire(r.type),
    amountPaise: r.amountPaise,
    category: r.category,
    description: r.description,
    date: IstDate.parseDate(r.txDate),
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
    syncVersion: r.syncVersion,
    syncState: switch (r.syncStatus) {
      'PENDING' => SyncState.pending,
      'FAILED' => SyncState.failed,
      _ => SyncState.synced,
    },
    syncError: r.syncError,
  );

  static LocalTransactionsCompanion _fromServer(Transaction t) =>
      LocalTransactionsCompanion.insert(
        id: t.id,
        groupId: t.groupId,
        type: t.type.wire,
        amountPaise: t.amountPaise,
        category: Value(t.category),
        description: Value(t.description),
        txDate: IstDate.toIsoDate(t.date),
        createdAt: (t.createdAt ?? DateTime.now()).toUtc(),
        updatedAt: Value(t.updatedAt?.toUtc()),
        syncVersion: Value(t.syncVersion),
        syncStatus: const Value('SYNCED'),
        syncError: const Value(null),
      );

  // ---------------------------------------------------------------- writes

  /// Saves a new transaction locally AND queues it, atomically (spec §20).
  Future<Transaction> insertPending(Transaction t) async {
    final now = DateTime.now().toUtc();
    await _db.transaction(() async {
      await _db
          .into(_db.localTransactions)
          .insert(
            LocalTransactionsCompanion.insert(
              id: t.id,
              groupId: t.groupId,
              type: t.type.wire,
              amountPaise: t.amountPaise,
              category: Value(t.category),
              description: Value(t.description),
              txDate: IstDate.toIsoDate(t.date),
              createdAt: now,
              syncStatus: const Value('PENDING'),
            ),
          );
      await _db
          .into(_db.outbox)
          .insert(
            OutboxCompanion.insert(
              id: t.id,
              operation: 'CREATE',
              entityType: 'TRANSACTION',
              entityId: t.id,
              payload: jsonEncode(createPayload(t)),
              status: 'PENDING',
              createdAt: now,
              updatedAt: now,
            ),
          );
    });
    return Transaction(
      id: t.id,
      groupId: t.groupId,
      type: t.type,
      amountPaise: t.amountPaise,
      category: t.category,
      description: t.description,
      date: t.date,
      createdAt: now,
      syncState: SyncState.pending,
    );
  }

  /// RPC parameters for `upsert_transaction` (no user reference).
  static Map<String, Object?> createPayload(Transaction t) => {
    'p_id': t.id,
    'p_group_id': t.groupId,
    'p_type': t.type.wire,
    'p_amount': Money.toNumericString(t.amountPaise),
    'p_category': t.category,
    'p_description': t.description,
    'p_transaction_date': IstDate.toIsoDate(t.date),
  };

  /// Caches server rows. Never overwrites a local PENDING/FAILED row.
  Future<void> upsertFromServer(Iterable<Transaction> rows) async {
    if (rows.isEmpty) return;
    await _db.transaction(() async {
      for (final t in rows) {
        final existing = await (_db.select(
          _db.localTransactions,
        )..where((r) => r.id.equals(t.id))).getSingleOrNull();
        if (existing != null && existing.syncStatus != 'SYNCED') continue;
        await _db
            .into(_db.localTransactions)
            .insertOnConflictUpdate(_fromServer(t));
      }
    });
  }

  /// The server accepted a queued write: replace with the server's row.
  Future<void> markSynced(Transaction serverRow) => _db
      .into(_db.localTransactions)
      .insertOnConflictUpdate(_fromServer(serverRow));

  Future<void> markFailed(String id, String reason) =>
      (_db.update(_db.localTransactions)..where((r) => r.id.equals(id))).write(
        LocalTransactionsCompanion(
          syncStatus: const Value('FAILED'),
          syncError: Value(reason),
        ),
      );

  Future<void> remove(String id) =>
      (_db.delete(_db.localTransactions)..where((r) => r.id.equals(id))).go();

  /// Drops cached SYNCED rows that the server no longer returns inside a
  /// fully-fetched window (they were deleted elsewhere).
  Future<void> reconcileWindow(
    TransactionFilter filter, {
    required TransactionCursor? after,
    required Transaction? lastInPage,
    required bool hasMore,
    required Set<String> serverIds,
  }) async {
    final query = _db.select(_db.localTransactions)
      ..where((r) => r.syncStatus.equals('SYNCED'))
      ..where((r) => _filterExpr(r, filter));
    if (after != null) query.where((r) => _beforeCursor(r, after));
    if (hasMore && lastInPage != null) {
      final last = TransactionCursor.after(lastInPage);
      // Only rows at or after the page's last key (i.e. inside this page).
      query.where((r) => _beforeCursor(r, last).not());
    }
    final stale = (await query.get()).where((r) => !serverIds.contains(r.id));
    for (final r in stale) {
      await remove(r.id);
    }
  }

  // ---------------------------------------------------------------- reads

  Expression<bool> _filterExpr($LocalTransactionsTable r, TransactionFilter f) {
    Expression<bool> e = const Constant(true);
    if (f.groupId != null) e = e & r.groupId.equals(f.groupId!);
    if (f.type != null) e = e & r.type.equals(f.type!.wire);
    if (f.from != null) {
      e = e & r.txDate.isBiggerOrEqualValue(IstDate.toIsoDate(f.from!));
    }
    if (f.to != null) {
      e = e & r.txDate.isSmallerOrEqualValue(IstDate.toIsoDate(f.to!));
    }
    if (f.category != null) {
      e = e & r.category.lower().equals(f.category!.trim().toLowerCase());
    }
    if (f.minPaise != null) {
      e = e & r.amountPaise.isBiggerOrEqualValue(f.minPaise!);
    }
    if (f.maxPaise != null) {
      e = e & r.amountPaise.isSmallerOrEqualValue(f.maxPaise!);
    }
    return e;
  }

  /// Rows strictly after [c] in (date desc, created desc, id desc) order.
  Expression<bool> _beforeCursor(
    $LocalTransactionsTable r,
    TransactionCursor c,
  ) {
    final date = IstDate.toIsoDate(c.date);
    final created = c.createdAt.toUtc();
    return r.txDate.isSmallerThanValue(date) |
        (r.txDate.equals(date) & r.createdAt.isSmallerThanValue(created)) |
        (r.txDate.equals(date) &
            r.createdAt.equals(created) &
            r.id.isSmallerThanValue(c.id));
  }

  List<OrderingTerm Function($LocalTransactionsTable)> get _order => [
    (r) => OrderingTerm.desc(r.txDate),
    (r) => OrderingTerm.desc(r.createdAt),
    (r) => OrderingTerm.desc(r.id),
  ];

  Future<TransactionPage> query(
    TransactionFilter filter, {
    TransactionCursor? after,
    int limit = 30,
  }) async {
    final q = _db.select(_db.localTransactions)
      ..where((r) => _filterExpr(r, filter))
      ..orderBy(_order)
      ..limit(limit + 1);
    if (after != null) q.where((r) => _beforeCursor(r, after));
    final rows = [for (final r in await q.get()) toDomain(r)];
    final hasMore = rows.length > limit;
    return TransactionPage(
      hasMore ? rows.sublist(0, limit) : rows,
      hasMore: hasMore,
      fromCache: true,
    );
  }

  Future<Transaction?> byId(String id) async {
    final row = await (_db.select(
      _db.localTransactions,
    )..where((r) => r.id.equals(id))).getSingleOrNull();
    return row == null ? null : toDomain(row);
  }

  /// Local PENDING/FAILED rows matching [filter], newest first.
  Future<List<Transaction>> unsynced(TransactionFilter filter) async {
    final q = _db.select(_db.localTransactions)
      ..where((r) => _filterExpr(r, filter))
      ..where((r) => r.syncStatus.isNotValue('SYNCED'))
      ..orderBy(_order);
    return [for (final r in await q.get()) toDomain(r)];
  }

  /// Sum of local rows (cached + queued) — the offline fallback for totals.
  Future<int> total(TransactionFilter filter) async {
    final sum = _db.localTransactions.amountPaise.sum();
    final q = _db.selectOnly(_db.localTransactions)
      ..addColumns([sum])
      ..where(_filterExpr(_db.localTransactions, filter));
    final row = await q.getSingle();
    return row.read(sum) ?? 0;
  }

  /// Number of writes still waiting for the server (PENDING or FAILED).
  Stream<int> watchUnsyncedCount() {
    final count = _db.localTransactions.id.count();
    final q = _db.selectOnly(_db.localTransactions)
      ..addColumns([count])
      ..where(_db.localTransactions.syncStatus.isNotValue('SYNCED'));
    return q.watchSingle().map((r) => r.read(count) ?? 0);
  }
}

final transactionsLocalDataSourceProvider =
    Provider<TransactionsLocalDataSource>(
      (ref) => TransactionsLocalDataSource(ref.watch(appDatabaseProvider)),
    );
