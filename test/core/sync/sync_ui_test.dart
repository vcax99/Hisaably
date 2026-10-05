import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/database/app_database.dart';
import 'package:hisaably/core/sync/outbox_processor.dart';
import 'package:hisaably/core/sync/sync_banner.dart';
import 'package:hisaably/core/sync/sync_bootstrap.dart';
import 'package:hisaably/core/sync/sync_engine.dart';
import 'package:hisaably/core/sync/transactions_local_data_source.dart';
import 'package:hisaably/features/transactions/application/transactions_providers.dart';
import 'package:hisaably/features/transactions/data/transactions_repository.dart';
import 'package:hisaably/features/transactions/domain/transaction.dart';
import 'package:hisaably/features/transactions/presentation/transactions_view.dart';

/// Outbox that never touches the network; records retry/discard calls.
class _FakeOutbox extends OutboxProcessor {
  _FakeOutbox(AppDatabase db)
    : super(
        db,
        TransactionsLocalDataSource(db),
        (_) => throw UnimplementedError(),
      );

  final retried = <String>[];
  final discarded = <String>[];
  FlushResult nextResult = const FlushResult(synced: 1);

  @override
  Future<FlushResult> retry(String transactionId) async {
    retried.add(transactionId);
    return nextResult;
  }

  @override
  Future<void> discard(String transactionId) async =>
      discarded.add(transactionId);
}

class _FakeEngine extends SyncEngine {
  _FakeEngine(OutboxProcessor outbox) : super(outbox, () async => true);

  FlushResult next = const FlushResult(synced: 2);
  var calls = 0;

  @override
  Future<FlushResult> sync(SyncTrigger trigger) async {
    calls++;
    return next;
  }
}

Transaction _tx(SyncState state, {String? error}) => Transaction(
  id: 't1',
  groupId: 'g1',
  type: TransactionType.expense,
  amountPaise: 85000,
  category: 'Food',
  date: DateTime.utc(2026, 9, 26),
  syncState: state,
  syncError: error,
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late _FakeOutbox outbox;
  late _FakeEngine engine;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    outbox = _FakeOutbox(db);
    engine = _FakeEngine(outbox);
  });
  tearDown(() async {
    engine.dispose();
    outbox.dispose();
    await db.close();
  });

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    int unsynced = 0,
    bool canManage = false,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localSyncEnabledProvider.overrideWithValue(true),
          unsyncedCountProvider.overrideWith((ref) => Stream.value(unsynced)),
          syncEngineProvider.overrideWithValue(engine),
          outboxProcessorProvider.overrideWithValue(outbox),
          canManageTransactionsProvider.overrideWith((ref, _) => canManage),
        ],
        retry: (_, _) => null,
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('SyncBanner', () {
    testWidgets('hidden when online and nothing queued', (tester) async {
      await pump(tester, const SyncBanner());
      expect(find.byKey(const Key('sync-banner')), findsNothing);
    });

    testWidgets('offline from cache shows when it was updated', (tester) async {
      await pump(tester, SyncBanner(cachedAt: DateTime.utc(2026, 9, 26, 8)));
      expect(find.textContaining('Offline · updated'), findsOneWidget);
      expect(find.byKey(const Key('sync-now')), findsNothing);
    });

    testWidgets('queued entries: count + Sync now → synced', (tester) async {
      await pump(tester, const SyncBanner(), unsynced: 2);
      expect(find.textContaining('2 waiting to sync'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sync-now')));
      await tester.pumpAndSettle();
      expect(engine.calls, 1);
      expect(find.text('All changes synced'), findsOneWidget);
    });

    testWidgets('Sync now while offline / with a rejection', (tester) async {
      await pump(tester, const SyncBanner(), unsynced: 1);
      engine.next = const FlushResult(offline: true);
      await tester.tap(find.byKey(const Key('sync-now')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Still offline'), findsOneWidget);

      ScaffoldMessenger.of(tester.element(find.byType(SyncBanner)))
          .clearSnackBars();
      engine.next = const FlushResult(failed: 1);
      await tester.tap(find.byKey(const Key('sync-now')));
      await tester.pumpAndSettle();
      expect(find.textContaining('could not be synced'), findsOneWidget);
    });
  });

  group('Unsynced entries', () {
    testWidgets('tiles show Pending / Not synced', (tester) async {
      await pump(
        tester,
        Column(
          children: [
            TransactionTile(transaction: _tx(SyncState.pending)),
            TransactionTile(transaction: _tx(SyncState.failed)),
            TransactionTile(transaction: _tx(SyncState.synced)),
          ],
        ),
      );
      expect(find.text('Pending'), findsOneWidget);
      expect(find.text('Not synced'), findsOneWidget);
    });

    Future<void> openSheet(WidgetTester tester, Transaction t) async {
      await pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showTransactionDetails(context, t),
            child: const Text('open'),
          ),
        ),
        canManage: true, // even a Group Admin can't edit before sync
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('failed: reason, Retry, no Edit', (tester) async {
      await openSheet(
        tester,
        _tx(SyncState.failed, error: 'This group is disabled.'),
      );
      expect(find.textContaining('This group is disabled.'), findsOneWidget);
      expect(find.text('Edit'), findsNothing);
      await tester.tap(find.byKey(const Key('tx-retry')));
      await tester.pumpAndSettle();
      expect(outbox.retried, ['t1']);
      expect(find.text('Expense synced'), findsOneWidget);
    });

    testWidgets('pending: Discard after confirm', (tester) async {
      await openSheet(tester, _tx(SyncState.pending));
      expect(find.textContaining('Will sync when online'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tx-discard')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Discard'));
      await tester.pumpAndSettle();
      expect(outbox.discarded, ['t1']);
      expect(find.text('Expense discarded'), findsOneWidget);
    });
  });
}
