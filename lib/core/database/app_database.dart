import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

part 'app_database.g.dart';

/// Local copy of the group ledger (offline-first). Like the server table it
/// carries NO user reference: transactions are collective.
@TableIndex(name: 'idx_local_tx_group_date', columns: {#groupId, #txDate})
class LocalTransactions extends Table {
  /// Client-generated UUID — the idempotent sync key.
  TextColumn get id => text()();
  TextColumn get groupId => text()();

  /// 'EXPENSE' | 'INCOME'
  TextColumn get type => text()();
  IntColumn get amountPaise => integer()();
  TextColumn get category => text().nullable()();
  TextColumn get description => text().nullable()();

  /// Calendar date 'YYYY-MM-DD' (IST accounting date).
  TextColumn get txDate => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime().nullable()();
  IntColumn get syncVersion => integer().withDefault(const Constant(1))();

  /// 'SYNCED' (mirrors the server) | 'PENDING' (queued) | 'FAILED' (rejected).
  TextColumn get syncStatus => text().withDefault(const Constant('SYNCED'))();

  /// User-safe reason when the server rejected a queued write.
  TextColumn get syncError => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Queue of writes waiting to reach the server (spec §21).
class Outbox extends Table {
  TextColumn get id => text()();

  /// 'CREATE'
  TextColumn get operation => text()();

  /// 'TRANSACTION'
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();

  /// JSON of the RPC parameters (no user reference).
  TextColumn get payload => text()();

  /// 'PENDING' | 'SYNCING' | 'SYNCED' | 'FAILED'
  TextColumn get status => text()();
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();

  /// Earliest time for the next attempt (exponential backoff).
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Last server responses for read-only views (groups, categories, dashboards)
/// so the app can open offline.
class CacheEntries extends Table {
  TextColumn get key => text()();
  TextColumn get json => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [LocalTransactions, Outbox, CacheEntries])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(
        executor ??
            driftDatabase(
              name: 'hisaably',
              // One connection for the app and the background-sync isolate,
              // so the UI's live queries see background writes.
              native: const DriftNativeOptions(shareAcrossIsolates: true),
            ),
      );

  @override
  int get schemaVersion => 1;

  /// Wipes everything local (used on sign-out).
  Future<void> clearAll() => transaction(() async {
    for (final table in allTables) {
      await delete(table).go();
    }
  });
}

/// Single database for the app's lifetime. Overridden in tests with an
/// in-memory database.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});
