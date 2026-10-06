import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/database/app_database.dart';
import 'package:hisaably/core/errors/app_failure.dart';
import 'package:hisaably/core/sync/cache_store.dart';
import 'package:hisaably/core/sync/outbox_processor.dart';
import 'package:hisaably/core/sync/transactions_local_data_source.dart';
import 'package:hisaably/core/utils/ist_date.dart';
import 'package:hisaably/core/utils/money.dart';
import 'package:hisaably/features/transactions/data/transactions_repository.dart';
import 'package:hisaably/features/transactions/domain/transaction.dart';

import '../../helpers/fake_transactions_repository.dart';

/// Server double whose reachability and failure mode the test controls.
class _Remote extends FakeTransactionsRepository {
  _Remote(super.db);

  bool offline = false;

  /// Thrown by the next sends instead of storing (business rejection etc.).
  AppFailure? rejectWith;
  int sends = 0;

  void _check() {
    if (offline) throw const NetworkFailure();
  }

  Future<Transaction> send(Map<String, Object?> p) async {
    sends++;
    _check();
    if (rejectWith != null) throw rejectWith!;
    return add(
      TransactionDraft(
        groupId: p['p_group_id']! as String,
        type: TransactionType.fromWire(p['p_type']! as String),
        amountPaise: Money.fromNumeric(p['p_amount']!),
        category: p['p_category'] as String?,
        description: p['p_description'] as String?,
        date: IstDate.parseDate(p['p_transaction_date']! as String),
      ),
      id: p['p_id']! as String,
    );
  }

  @override
  Future<TransactionPage> list(
    TransactionFilter filter, {
    TransactionCursor? after,
    int limit = 30,
  }) async {
    _check();
    return super.list(filter, after: after, limit: limit);
  }

  @override
  Future<int> total(TransactionFilter filter) async {
    _check();
    return super.total(filter);
  }

  @override
  Future<Transaction> update(
    String id,
    TransactionDraft draft, {
    required int expectedVersion,
  }) async {
    _check();
    return super.update(id, draft, expectedVersion: expectedVersion);
  }

  @override
  Future<void> delete(String id, {required int expectedVersion}) async {
    _check();
    return super.delete(id, expectedVersion: expectedVersion);
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late FakeLedger ledger;
  late _Remote remote;
  late TransactionsLocalDataSource local;
  late OutboxProcessor outbox;
  late OfflineFirstTransactionsRepository repo;
  late DateTime now;

  const g = 'group-1';
  final today = IstDate.today();
  TransactionDraft draft(int paise, {String? category = 'Food'}) =>
      TransactionDraft(
        groupId: g,
        type: TransactionType.expense,
        amountPaise: paise,
        category: category,
        date: today,
      );

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    ledger = FakeLedger(canManage: true)..seedCategories(g);
    remote = _Remote(ledger);
    local = TransactionsLocalDataSource(db);
    now = DateTime.utc(2026, 10, 1, 12);
    outbox = OutboxProcessor(db, local, remote.send, clock: () => now);
    repo = OfflineFirstTransactionsRepository(remote, local, outbox);
  });

  tearDown(() async {
    outbox.dispose();
    await db.close();
  });

  test('online add reaches the server immediately and is SYNCED', () async {
    final t = await repo.add(draft(85000));
    expect(t.isSynced, isTrue);
    expect(ledger.transactions, contains(t.id));
    expect(await outbox.unsyncedCount(), 0);
  });

  test(
    'offline add is saved locally, listed, and counted as pending',
    () async {
      remote.offline = true;
      final t = await repo.add(draft(85000));
      expect(t.isPending, isTrue);
      expect(ledger.transactions, isEmpty);
      expect(await outbox.unsyncedCount(), 1);

      final page = await repo.list(const TransactionFilter(groupId: g));
      expect(page.fromCache, isTrue);
      expect(page.items.single.id, t.id);
      expect(await repo.total(const TransactionFilter(groupId: g)), 85000);
    },
  );

  test('pending entries sync once back online, without duplicates', () async {
    remote.offline = true;
    final a = await repo.add(draft(1000));
    final b = await repo.add(draft(2000));
    remote.offline = false;

    final results = <FlushResult>[];
    final sub = outbox.results.listen(results.add);
    final r = await outbox.flush(force: true);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(r.synced, 2);
    expect(results.single.synced, 2);
    expect(ledger.transactions.keys, containsAll([a.id, b.id]));
    expect(ledger.transactions, hasLength(2));
    expect((await local.byId(a.id))!.isSynced, isTrue);

    // A second flush (e.g. resume) sends nothing again.
    final sendsBefore = remote.sends;
    await outbox.flush(force: true);
    expect(remote.sends, sendsBefore);
  });

  test('a lost response is retried idempotently (same id, one row)', () async {
    remote.offline = true;
    final t = await repo.add(draft(500));
    // Server stored it but the app never saw the reply.
    remote.offline = false;
    await remote.send(LocalDataPayload.of(t));
    expect(ledger.transactions, hasLength(1));

    await outbox.flush(force: true);
    expect(ledger.transactions, hasLength(1));
    expect((await local.byId(t.id))!.isSynced, isTrue);
  });

  test('respects backoff unless forced', () async {
    remote.offline = true;
    await repo.add(draft(500));
    final item = (await outbox.all()).single;
    expect(item.retryCount, 1);
    expect(
      item.nextAttemptAt!.isAtSameMomentAs(now.add(OutboxProcessor.backoff(1))),
      isTrue,
    );

    remote.offline = false;
    expect((await outbox.flush()).synced, 0); // not due yet
    now = now.add(const Duration(minutes: 1));
    expect((await outbox.flush()).synced, 1);
  });

  test('backoff grows exponentially and is capped at 30 minutes', () {
    expect(OutboxProcessor.backoff(0), const Duration(seconds: 5));
    expect(OutboxProcessor.backoff(3), const Duration(seconds: 40));
    expect(OutboxProcessor.backoff(20), const Duration(minutes: 30));
  });

  test('business rejection parks the item as FAILED with a reason', () async {
    remote.rejectWith = const PermissionFailure(
      'This group is disabled. New entries are not allowed.',
    );
    final t = await repo.add(draft(700));
    expect(t.isFailed, isTrue);
    expect(t.syncError, contains('disabled'));
    expect((await outbox.all()).single.status, 'FAILED');
    // FAILED is kept (not retried automatically) …
    expect((await outbox.flush(force: true)).synced, 0);

    // … until the user retries.
    remote.rejectWith = null;
    final r = await outbox.retry(t.id);
    expect(r.synced, 1);
    expect((await local.byId(t.id))!.isSynced, isTrue);
  });

  test('a re-send of an entry deleted meanwhile just disappears', () async {
    // Hard delete: the server refuses to re-create a deleted id.
    remote.rejectWith = const RuleFailure('DELETED', 'This entry was deleted.');
    final t = await repo.add(draft(700));
    expect(await local.byId(t.id), isNull);
    expect((await outbox.all()).single.status, 'SYNCED');
  });

  test('server errors retry with backoff, then FAILED after max', () async {
    remote.rejectWith = const UnexpectedFailure();
    final t = await repo.add(draft(700));
    expect(t.isPending, isTrue, reason: '${(await outbox.all()).single}');
    for (var i = 1; i < OutboxProcessor.maxAttempts; i++) {
      now = now.add(const Duration(hours: 1));
      await outbox.flush();
    }
    expect((await outbox.all()).single.status, 'FAILED');
    expect((await local.byId(t.id))!.isFailed, isTrue);
  });

  test('discard drops an unsynced entry from device and queue', () async {
    remote.offline = true;
    final t = await repo.add(draft(700));
    await repo.delete(t.id, expectedVersion: 1);
    expect(await local.byId(t.id), isNull);
    expect(await outbox.unsyncedCount(), 0);
  });

  test('SYNCING left by a crash is recovered and re-sent', () async {
    remote.offline = true;
    final t = await repo.add(draft(700));
    await db.customStatement("UPDATE outbox SET status = 'SYNCING'");
    remote.offline = false;
    expect((await outbox.flush(force: true)).synced, 1);
    expect(ledger.transactions, contains(t.id));
  });

  test('online list merges this device\'s unsynced rows first', () async {
    ledger.seed(g, TransactionType.expense, 100, category: 'Rent');
    remote.offline = true;
    final pending = await repo.add(draft(200));
    remote.offline = false;
    remote.rejectWith = const PermissionFailure('nope'); // keep it unsynced
    final page = await repo.list(const TransactionFilter(groupId: g));
    expect(page.items.map((t) => t.id), contains(pending.id));
    expect(page.items, hasLength(2));
  });

  test('rows deleted on the server disappear from the cache', () async {
    final a = ledger.seed(g, TransactionType.expense, 100);
    final b = ledger.seed(g, TransactionType.expense, 200);
    const f = TransactionFilter(groupId: g);
    await repo.list(f);
    expect((await local.query(f)).items, hasLength(2));

    ledger.transactions.remove(a.id);
    await repo.list(f);
    final cached = (await local.query(f)).items;
    expect(cached.map((t) => t.id), [b.id]);
  });

  test('editing needs a connection', () async {
    final t = await repo.add(draft(700));
    remote.offline = true;
    expect(
      () => repo.update(t.id, draft(900), expectedVersion: t.syncVersion),
      throwsA(isA<NetworkFailure>()),
    );
  });

  test('payloads carry no user reference', () {
    final p = TransactionsLocalDataSource.createPayload(
      Transaction(
        id: 'x',
        groupId: g,
        type: TransactionType.income,
        amountPaise: 2000000,
        date: today,
      ),
    );
    expect(
      p.keys.where((k) => k.contains('user') || k.contains('member')),
      isEmpty,
    );
    expect(p['p_amount'], '20000.00');
  });

  test('clearAll wipes ledger, queue and cache', () async {
    remote.offline = true;
    await repo.add(draft(700));
    final cache = CacheStore(db);
    await cache.put('k', {'a': 1});
    await db.clearAll();
    expect(await outbox.unsyncedCount(), 0);
    expect(await cache.get('k'), isNull);
  });

  group('fetchWithCache', () {
    test('falls back to the last response when offline', () async {
      final cache = CacheStore(db);
      final fresh = await fetchWithCache(
        cache,
        'k',
        () async => [1, 2],
        (raw, at) => (raw, at),
      );
      expect(fresh.$2, isNull);
      final stale = await fetchWithCache(
        cache,
        'k',
        () async => throw const NetworkFailure(),
        (raw, at) => (raw, at),
      );
      expect(stale.$1, [1, 2]);
      expect(stale.$2, isNotNull);
    });

    test('rethrows when offline with nothing cached', () async {
      expect(
        () => fetchWithCache(
          CacheStore(db),
          'missing',
          () async => throw const NetworkFailure(),
          (raw, at) => raw,
        ),
        throwsA(isA<NetworkFailure>()),
      );
    });

    test('non-network errors are not masked by the cache', () async {
      final cache = CacheStore(db);
      await cache.put('k', 1);
      expect(
        () => fetchWithCache(
          cache,
          'k',
          () async => throw const PermissionFailure('no'),
          (raw, at) => raw,
        ),
        throwsA(isA<PermissionFailure>()),
      );
    });
  });
}

extension LocalDataPayload on Transaction {
  static Map<String, Object?> of(Transaction t) =>
      TransactionsLocalDataSource.createPayload(t);
}
