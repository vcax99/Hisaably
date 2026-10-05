import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/database/app_database.dart';
import 'package:hisaably/core/errors/app_failure.dart';
import 'package:hisaably/core/network/network_status.dart';
import 'package:hisaably/core/sync/outbox_processor.dart';
import 'package:hisaably/core/sync/sync_engine.dart';
import 'package:hisaably/core/sync/transactions_local_data_source.dart';
import 'package:hisaably/core/utils/ist_date.dart';
import 'package:hisaably/features/transactions/domain/transaction.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late TransactionsLocalDataSource local;
  late OutboxProcessor outbox;
  late DateTime now;
  var sends = 0;
  AppFailure? failWith;
  var reachable = true;
  var reachChecks = 0;
  final network = NetworkStatus.instance;

  Future<Transaction> send(Map<String, Object?> p) async {
    sends++;
    if (failWith != null) throw failWith!;
    return Transaction(
      id: p['p_id']! as String,
      groupId: p['p_group_id']! as String,
      type: TransactionType.expense,
      amountPaise: 100,
      date: IstDate.today(),
      createdAt: now,
    );
  }

  final engines = <SyncEngine>[];
  SyncEngine track(SyncEngine e) {
    engines.add(e);
    return e;
  }

  SyncEngine engine({List<Duration>? regainDelays}) => track(
    SyncEngine(
      outbox,
      () async {
        reachChecks++;
        return reachable;
      },
      network: network,
      clock: () => now,
      regainDelays: regainDelays ?? const [Duration.zero],
    ),
  );

  Future<void> queue(String id) => local.insertPending(
    Transaction(
      id: id,
      groupId: 'g',
      type: TransactionType.expense,
      amountPaise: 100,
      date: IstDate.today(),
    ),
  );

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    local = TransactionsLocalDataSource(db);
    now = DateTime.utc(2026, 10, 1, 12);
    outbox = OutboxProcessor(db, local, send, clock: () => now);
    sends = 0;
    failWith = null;
    reachable = true;
    reachChecks = 0;
    network.debugSet(true);
  });

  tearDown(() async {
    for (final e in engines) {
      e.dispose();
    }
    engines.clear();
    network.debugSet(true);
    outbox.dispose();
    await db.close();
  });

  test('no network: nothing is checked or sent', () async {
    await queue('a');
    network.debugSet(false);
    final r = await engine().sync(SyncTrigger.manual);
    expect(r.offline, isTrue);
    expect(reachChecks, 0);
    expect(sends, 0);
  });

  test(
    'network but server unreachable: nothing sent, no polling timer',
    () async {
      await queue('a');
      reachable = false;
      final e = engine();
      final r = await e.sync(SyncTrigger.manual);
      expect(r.offline, isTrue);
      expect(sends, 0);
      expect(e.hasScheduledTimer, isFalse);
    },
  );

  test('reachable: sends even items still in backoff (forced)', () async {
    await queue('a');
    failWith = const NetworkFailure();
    await outbox.flush(force: true); // now rescheduled into the future
    failWith = null;
    sends = 0;
    final r = await engine().sync(SyncTrigger.resume);
    expect(r.synced, 1);
    expect(sends, 1);
  });

  test('scheduled trigger respects backoff', () async {
    await queue('a');
    failWith = const NetworkFailure();
    await outbox.flush(force: true);
    failWith = null;
    sends = 0;
    expect((await engine().sync(SyncTrigger.scheduled)).synced, 0);
    now = now.add(const Duration(minutes: 1));
    expect((await engine().sync(SyncTrigger.scheduled)).synced, 1);
  });

  test('network regained: re-checks reachability before giving up', () async {
    await queue('a');
    var calls = 0;
    final e = track(
      SyncEngine(
        outbox,
        () async => ++calls >= 3, // captive portal clears on the 3rd check
        network: network,
        clock: () => now,
        regainDelays: const [Duration.zero, Duration.zero, Duration.zero],
      ),
    );
    final r = await e.sync(SyncTrigger.networkRegained);
    expect(calls, 3);
    expect(r.synced, 1);
  });

  test('network regained but never reachable: gives up, keeps item', () async {
    await queue('a');
    reachable = false;
    final r = await engine(regainDelays: const [Duration.zero, Duration.zero])
        .sync(SyncTrigger.networkRegained);
    expect(r.offline, isTrue);
    expect(reachChecks, 2);
    expect(await outbox.unsyncedCount(), 1);
  });

  test('server error → one timer for the retry; it fires and syncs', () async {
    await queue('a');
    failWith = const UnexpectedFailure();
    final e = engine();
    await e.sync(SyncTrigger.manual);
    expect(e.hasScheduledTimer, isTrue);

    // Time passes (backoff over); the timer (clamped to ≥1s) retries.
    failWith = null;
    now = now.add(const Duration(hours: 1));
    await e.reschedule();
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(await outbox.unsyncedCount(), 0);
    expect(e.hasScheduledTimer, isFalse, reason: 'queue empty, no timer');
    e.dispose();
  });

  test('no timer in the background; resume syncs', () async {
    await queue('a');
    failWith = const UnexpectedFailure();
    final e = engine();
    await e.sync(SyncTrigger.manual);
    expect(e.hasScheduledTimer, isTrue);
    e.paused();
    expect(e.hasScheduledTimer, isFalse);
    await e.reschedule();
    expect(e.hasScheduledTimer, isFalse, reason: 'paused');

    failWith = null;
    final r = await e.resumed();
    expect(r.synced, 1);
    e.dispose();
  });

  test('nothing queued: no timer', () async {
    final e = engine();
    await e.sync(SyncTrigger.startup);
    expect(e.hasScheduledTimer, isFalse);
    e.dispose();
  });
}
