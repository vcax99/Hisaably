// Live test: get_group_balances (Dashboard "By group") against dev —
// per-group numbers, month window, soft deletes ignored, visibility.
// Run with scripts/run_live_tests.sh.
@Tags(['live'])
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/utils/ist_date.dart';
import 'package:hisaably/features/auth/domain/username.dart';
import 'package:hisaably/features/dashboard/data/dashboard_repository.dart';
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

void main() {
  late SupabaseClient admin;
  final run = _random(6);
  final password = _random(16);
  final ids = <String, String>{};
  final groups = <String, String>{};
  final today = IstDate.today();
  final thisMonth = DateTime.utc(today.year, today.month);
  final lastMonth = DateTime.utc(today.year, today.month - 1, 10);

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
    for (final role in ['dmem', 'dsa']) {
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
    await admin
        .from('profiles')
        .update({'role': 'SUPER_ADMIN'})
        .eq('id', ids['dsa']!);
    for (final g in ['A', 'B', 'C']) {
      final row = await admin
          .from('groups')
          .insert({'name': 'Live Dash $g $run'})
          .select('id')
          .single();
      groups[g] = row['id'] as String;
    }
    await admin.from('group_members').insert([
      {'group_id': groups['A'], 'user_id': ids['dmem'], 'group_role': 'MEMBER'},
      {'group_id': groups['B'], 'user_id': ids['dmem'], 'group_role': 'MEMBER'},
    ]);
    // Through the real API as the Super Admin (any group).
    final txs = SupabaseTransactionsRepository(await clientAs('dsa'));
    Future<Transaction> add(
      String g,
      TransactionType type,
      int paise,
      DateTime date,
    ) => txs.add(
      TransactionDraft(
        groupId: groups[g]!,
        type: type,
        amountPaise: paise,
        date: date,
        category: type == TransactionType.expense ? 'Food' : null,
      ),
    );
    // A: 1000 income last month, 300 expense this month, 50 deleted.
    await add('A', TransactionType.income, 100000, lastMonth);
    await add('A', TransactionType.expense, 30000, today);
    final gone = await add('A', TransactionType.expense, 5000, today);
    await txs.delete(gone.id, expectedVersion: gone.syncVersion);
    // B: 200 income this month. C: not the member's group.
    await add('B', TransactionType.income, 20000, today);
    await add('C', TransactionType.income, 99900, today);
  });

  tearDownAll(() async {
    if (_skip != null) return;
    for (final g in groups.values) {
      await admin.from('notifications').delete().eq('group_id', g);
      await admin.from('transactions').delete().eq('group_id', g);
      await admin.from('group_members').delete().eq('group_id', g);
      await admin.from('group_categories').delete().eq('group_id', g);
      await admin.from('groups').delete().eq('id', g);
    }
    for (final id in ids.values) {
      await admin.auth.admin.deleteUser(id);
    }
  });

  test('member sees only their groups, with correct numbers', () async {
    final repo = SupabaseDashboardRepository(await clientAs('dmem'));
    final rows = await repo.getGroupBalances(month: thisMonth);
    final byId = {for (final r in rows) r.groupId: r};
    expect(byId.keys.toSet(), {groups['A'], groups['B']});

    final a = byId[groups['A']]!;
    expect(a.currentBalancePaise, 70000, reason: '1000 − 300; deleted ignored');
    expect(a.monthIncomePaise, 0, reason: 'income was last month');
    expect(a.monthExpensePaise, 30000);

    final b = byId[groups['B']]!;
    expect(b.currentBalancePaise, 20000);
    expect(b.monthIncomePaise, 20000);

    // Last month's window.
    final prev = await repo.getGroupBalances(
      month: DateTime.utc(lastMonth.year, lastMonth.month),
    );
    expect(
      prev.firstWhere((r) => r.groupId == groups['A']).monthIncomePaise,
      100000,
    );
  }, skip: _skip);

  test('Super Admin sees every group', () async {
    final repo = SupabaseDashboardRepository(await clientAs('dsa'));
    final rows = await repo.getGroupBalances(month: thisMonth);
    expect(
      rows.map((r) => r.groupId).toSet(),
      containsAll([groups['A'], groups['B'], groups['C']]),
    );
  }, skip: _skip);
}
