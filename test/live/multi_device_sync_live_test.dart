// Live test (spec §23 "multi-device sync"): two devices of two group members
// record entries while offline, then sync — concurrently, with a replayed
// send. Every entry must survive exactly once (no last-write-wins), a
// category created on both devices must exist once, and monthly balances
// (incl. a backdated month's carry-forward) must be correct.
// Run with scripts/run_live_tests.sh.
@Tags(['live'])
library;

import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/database/app_database.dart';
import 'package:hisaably/core/errors/app_failure.dart';
import 'package:hisaably/core/sync/outbox_processor.dart';
import 'package:hisaably/core/sync/transactions_local_data_source.dart';
import 'package:hisaably/core/utils/ist_date.dart';
import 'package:hisaably/core/utils/money.dart';
import 'package:hisaably/features/auth/domain/username.dart';
import 'package:hisaably/features/transactions/data/transactions_repository.dart';
import 'package:hisaably/features/transactions/domain/transaction.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _env = Platform.environment;
final _url = _env['SUPABASE_URL'];
final _publishable = _env['SUPABASE_PUBLISHABLE_KEY'];
final _service = _env['SUPABASE_SERVICE_ROLE_KEY'];
final _skip = (_url == null || _publishable == null || _service == null)
    ? 'Live keys not set (run scripts/run_live_tests.sh)'
    : null;

String _random(int n) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final r = Random.secure();
  return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
}

/// One phone: its own SQLite + outbox, talking to the real backend, with an
/// "airplane mode" switch.
class _Device {
  _Device(this.client) {
    final remote = SupabaseTransactionsRepository(client);
    outbox = OutboxProcessor(db, local, (payload) {
      sends.add(payload);
      if (offline) throw const NetworkFailure();
      return remote.sendCreate(payload);
    });
    repo = OfflineFirstTransactionsRepository(remote, local, outbox);
  }

  final SupabaseClient client;
  final db = AppDatabase(NativeDatabase.memory());
  late final local = TransactionsLocalDataSource(db);
  late final OutboxProcessor outbox;
  late final OfflineFirstTransactionsRepository repo;
  final sends = <Map<String, Object?>>[];
  bool offline = true;

  Future<void> close() async {
    outbox.dispose();
    await db.close();
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late SupabaseClient admin;
  final run = _random(6);
  final password = _random(16);
  final ids = <String, String>{};
  late String groupId;
  final today = IstDate.today();
  final thisMonth = DateTime.utc(today.year, today.month);
  final lastMonth = DateTime.utc(today.year, today.month - 1);

  Future<SupabaseClient> clientAs(String role) async {
    final client = SupabaseClient(
      _url!,
      _publishable!,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    await client.auth.signInWithPassword(
      email: Username.toAuthEmail('live_${role}_$run'),
      password: password,
    );
    return client;
  }

  setUpAll(() async {
    if (_skip != null) return;
    admin = SupabaseClient(
      _url!,
      _service!,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    for (final role in ['phone1', 'phone2']) {
      final res = await admin.auth.admin.createUser(
        AdminUserAttributes(
          email: Username.toAuthEmail('live_${role}_$run'),
          password: password,
          emailConfirm: true,
          userMetadata: {'username': 'live_${role}_$run', 'name': 'Live $role'},
        ),
      );
      ids[role] = res.user!.id;
    }
    final group = await admin
        .from('groups')
        .insert({'name': 'Live Multi $run'})
        .select('id')
        .single();
    groupId = group['id'] as String;
    await admin.from('group_members').insert([
      {'group_id': groupId, 'user_id': ids['phone1'], 'group_role': 'MEMBER'},
      {
        'group_id': groupId,
        'user_id': ids['phone2'],
        'group_role': 'GROUP_ADMIN',
      },
    ]);
  });

  tearDownAll(() async {
    if (_skip != null) return;
    await admin.from('notifications').delete().eq('group_id', groupId);
    await admin.from('transactions').delete().eq('group_id', groupId);
    await admin.from('group_members').delete().eq('group_id', groupId);
    await admin.from('group_categories').delete().eq('group_id', groupId);
    await admin.from('groups').delete().eq('id', groupId);
    for (final id in ids.values) {
      await admin.auth.admin.deleteUser(id);
    }
  });

  test(
    'two offline devices: every entry survives once, balances add up',
    () async {
      final a = _Device(await clientAs('phone1'));
      final b = _Device(await clientAs('phone2'));
      final snacks = 'Snacks$run';

      // Both phones offline, recording independently.
      final a1 = await a.repo.add(
        TransactionDraft(
          groupId: groupId,
          type: TransactionType.expense,
          amountPaise: 50000,
          category: snacks,
          date: today,
        ),
      );
      final b1 = await b.repo.add(
        TransactionDraft(
          groupId: groupId,
          type: TransactionType.income,
          amountPaise: 200000,
          date: lastMonth.add(const Duration(days: 9)), // backdated
        ),
      );
      final b2 = await b.repo.add(
        TransactionDraft(
          groupId: groupId,
          type: TransactionType.expense,
          amountPaise: 30000,
          category: snacks.toLowerCase(), // same new category, other case
          date: today,
        ),
      );
      for (final t in [a1, b1, b2]) {
        expect(t.isPending, isTrue);
      }

      // Back online: both sync at the same time.
      a.offline = false;
      b.offline = false;
      final results = await Future.wait([
        a.outbox.flush(force: true),
        b.outbox.flush(force: true),
      ]);
      expect(results[0].synced, 1);
      expect(results[1].synced, 2);

      // A lost response: phone 1 sends the same entry again.
      await a.client.rpc<dynamic>('upsert_transaction', params: a.sends.first);
      expect((await a.outbox.flush(force: true)).synced, 0);

      // Server: exactly the three entries.
      final rows = await admin
          .from('transactions')
          .select('id, amount, category')
          .eq('group_id', groupId)
          .isFilter('deleted_at', null);
      expect(rows.map((r) => r['id']).toSet(), {a1.id, b1.id, b2.id});
      expect(rows, hasLength(3));

      // The category made on both phones exists once.
      final cats = await admin
          .from('group_categories')
          .select('name')
          .eq('group_id', groupId)
          .ilike('name', snacks);
      expect(cats, hasLength(1));

      // Balances: backdated income carries into this month.
      final balances = await a.client.rpc<List<dynamic>>(
        'get_monthly_balances',
        params: {
          'p_group_id': groupId,
          'p_from_month': IstDate.toIsoDate(lastMonth),
          'p_to_month': IstDate.toIsoDate(thisMonth),
        },
      );
      final byMonth = {
        for (final m in balances.cast<Map<String, dynamic>>())
          m['month_start'] as String: m,
      };
      final last = byMonth[IstDate.toIsoDate(lastMonth)]!;
      final now = byMonth[IstDate.toIsoDate(thisMonth)]!;
      expect(Money.fromNumeric(last['closing_balance'] as Object), 200000);
      expect(Money.fromNumeric(now['opening_balance'] as Object), 200000);
      expect(Money.fromNumeric(now['total_expense'] as Object), 80000);
      expect(Money.fromNumeric(now['closing_balance'] as Object), 120000);

      // Each phone, once refreshed, sees the other phone's entries.
      for (final d in [a, b]) {
        final page = await d.repo.list(
          TransactionFilter(groupId: groupId, from: lastMonth, to: today),
        );
        expect(page.items.map((t) => t.id).toSet(), {a1.id, b1.id, b2.id});
        expect(page.items.every((t) => t.isSynced), isTrue);
      }

      await a.close();
      await b.close();
    },
    skip: _skip,
  );
}
