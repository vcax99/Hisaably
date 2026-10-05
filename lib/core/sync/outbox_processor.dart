import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../features/transactions/domain/transaction.dart';
import '../database/app_database.dart';
import '../errors/app_failure.dart';
import '../errors/error_mapper.dart';
import 'transactions_local_data_source.dart';

/// Sends one queued create to the server (`upsert_transaction`, idempotent
/// on the client id) and returns the stored row.
typedef SendCreate = Future<Transaction> Function(Map<String, Object?> payload);

class FlushResult {
  const FlushResult({this.synced = 0, this.failed = 0, this.offline = false});

  final int synced;
  final int failed;

  /// Stopped because the server couldn't be reached.
  final bool offline;
}

/// Drains the outbox (spec §20–22). Safe to call often: a single flush runs
/// at a time, items are processed oldest-first, and the server dedupes on the
/// transaction id, so a retry after a lost response never duplicates.
class OutboxProcessor {
  OutboxProcessor(
    this._db,
    this._local,
    this._send, {
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final TransactionsLocalDataSource _local;
  final SendCreate _send;
  final DateTime Function() _clock;
  Future<FlushResult>? _inFlight;
  final _results = StreamController<FlushResult>.broadcast();

  /// Emits after every flush that synced or failed something, so lists and
  /// dashboards can refresh.
  Stream<FlushResult> get results => _results.stream;

  void dispose() => _results.close();

  /// Server errors (5xx/unknown) before an item is parked as FAILED.
  static const maxAttempts = 8;

  static Duration backoff(int retryCount) =>
      Duration(seconds: math.min(5 * math.pow(2, retryCount).toInt(), 30 * 60));

  /// Processes due PENDING items. [force] ignores the backoff schedule
  /// (manual "Sync now", connectivity regained).
  Future<FlushResult> flush({bool force = false}) =>
      _inFlight ??= _flush(force)
          .then((r) {
            if ((r.synced > 0 || r.failed > 0) && !_results.isClosed) {
              _results.add(r);
            }
            return r;
          })
          .whenComplete(() => _inFlight = null);

  Future<FlushResult> _flush(bool force) async {
    await _recoverInterrupted();
    var synced = 0;
    var failed = 0;
    // Each item is tried at most once per flush (a forced flush ignores the
    // backoff, so a rescheduled item would otherwise be picked again).
    final tried = <String>{};
    while (true) {
      final now = _clock().toUtc();
      final query = _db.select(_db.outbox)
        ..where((o) => o.status.equals('PENDING'))
        ..orderBy([(o) => OrderingTerm.asc(o.createdAt)])
        ..limit(1);
      if (tried.isNotEmpty) query.where((o) => o.id.isNotIn(tried));
      if (!force) {
        query.where(
          (o) =>
              o.nextAttemptAt.isNull() |
              o.nextAttemptAt.isSmallerOrEqualValue(now),
        );
      }
      final item = await query.getSingleOrNull();
      if (item == null) break;
      tried.add(item.id);

      await _setStatus(item.id, 'SYNCING');
      try {
        final payload = (jsonDecode(item.payload) as Map)
            .cast<String, Object?>();
        final row = await _send(payload);
        await _db.transaction(() async {
          await _local.markSynced(row);
          await _setStatus(item.id, 'SYNCED', clearError: true);
        });
        synced++;
      } catch (e, st) {
        final failure = mapError(e, st);
        switch (failure) {
          case NetworkFailure():
            await _reschedule(item, failure.message);
            return FlushResult(synced: synced, failed: failed, offline: true);
          case SessionExpiredFailure():
            // Not the item's fault: keep it for after the next sign-in.
            await _reschedule(item, failure.message);
            return FlushResult(synced: synced, failed: failed);
          case UnexpectedFailure() when item.retryCount + 1 < maxAttempts:
            await _reschedule(item, failure.message);
          default:
            // Business rejection (validation, permission, disabled account
            // or group, …) or too many server errors: park it for review.
            await _db.transaction(() async {
              await _local.markFailed(item.entityId, failure.message);
              await (_db.update(
                _db.outbox,
              )..where((o) => o.id.equals(item.id))).write(
                OutboxCompanion(
                  status: const Value('FAILED'),
                  retryCount: Value(item.retryCount + 1),
                  lastError: Value(failure.message),
                  updatedAt: Value(_clock().toUtc()),
                ),
              );
            });
            failed++;
        }
      }
    }
    await _pruneSynced();
    return FlushResult(synced: synced, failed: failed);
  }

  /// After a crash/kill mid-send, SYNCING items go back to PENDING. Safe:
  /// the server dedupes on the id.
  Future<void> _recoverInterrupted() =>
      (_db.update(_db.outbox)..where((o) => o.status.equals('SYNCING'))).write(
        const OutboxCompanion(status: Value('PENDING')),
      );

  Future<void> _setStatus(
    String id,
    String status, {
    bool clearError = false,
  }) => (_db.update(_db.outbox)..where((o) => o.id.equals(id))).write(
    OutboxCompanion(
      status: Value(status),
      lastError: clearError ? const Value(null) : const Value.absent(),
      updatedAt: Value(_clock().toUtc()),
    ),
  );

  Future<void> _reschedule(OutboxData item, String reason) {
    final retries = item.retryCount + 1;
    return (_db.update(_db.outbox)..where((o) => o.id.equals(item.id))).write(
      OutboxCompanion(
        status: const Value('PENDING'),
        retryCount: Value(retries),
        lastError: Value(reason),
        nextAttemptAt: Value(_clock().toUtc().add(backoff(retries))),
        updatedAt: Value(_clock().toUtc()),
      ),
    );
  }

  /// Keep SYNCED records a week for diagnostics, then drop them.
  Future<void> _pruneSynced() =>
      (_db.delete(_db.outbox)
            ..where((o) => o.status.equals('SYNCED'))
            ..where(
              (o) => o.updatedAt.isSmallerThanValue(
                _clock().toUtc().subtract(const Duration(days: 7)),
              ),
            ))
          .go();

  /// Re-queues a FAILED item (e.g. after an admin re-enabled the group).
  Future<FlushResult> retry(String transactionId) async {
    await _db.transaction(() async {
      await (_db.update(
        _db.outbox,
      )..where((o) => o.entityId.equals(transactionId))).write(
        OutboxCompanion(
          status: const Value('PENDING'),
          retryCount: const Value(0),
          nextAttemptAt: const Value(null),
          updatedAt: Value(_clock().toUtc()),
        ),
      );
      await (_db.update(
        _db.localTransactions,
      )..where((r) => r.id.equals(transactionId))).write(
        const LocalTransactionsCompanion(
          syncStatus: Value('PENDING'),
          syncError: Value(null),
        ),
      );
    });
    return flush(force: true);
  }

  /// Drops a queued/failed transaction that never reached the server.
  Future<void> discard(String transactionId) => _db.transaction(() async {
    await (_db.delete(
      _db.outbox,
    )..where((o) => o.entityId.equals(transactionId))).go();
    await _local.remove(transactionId);
  });

  /// Writes not yet accepted by the server (PENDING/SYNCING/FAILED).
  Future<int> unsyncedCount() async {
    final count = _db.outbox.id.count();
    final q = _db.selectOnly(_db.outbox)
      ..addColumns([count])
      ..where(_db.outbox.status.isNotValue('SYNCED'));
    return (await q.getSingle()).read(count) ?? 0;
  }

  /// When the earliest queued (PENDING) item is due, or null if none.
  Future<DateTime?> nextDueAt() async {
    final item =
        await (_db.select(_db.outbox)
              ..where((o) => o.status.equals('PENDING'))
              ..orderBy([
                (o) => OrderingTerm(
                  expression: o.nextAttemptAt,
                  nulls: NullsOrder.first,
                ),
              ])
              ..limit(1))
            .getSingleOrNull();
    if (item == null) return null;
    return item.nextAttemptAt ?? _clock().toUtc();
  }

  @visibleForTesting
  Future<List<OutboxData>> all() => _db.select(_db.outbox).get();
}
