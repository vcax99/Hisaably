// Live test: TransactionsRepository + CategoriesRepository against the dev
// backend, as a plain member and as the group's Group Admin.
// Run with scripts/run_live_tests.sh.
@Tags(['live'])
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/errors/app_failure.dart';
import 'package:hisaably/core/utils/ist_date.dart';
import 'package:hisaably/features/auth/domain/username.dart';
import 'package:hisaably/features/transactions/data/transactions_repository.dart';
import 'package:hisaably/features/transactions/domain/transaction.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

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
  late String groupId;
  final today = IstDate.today();
  final monthStart = DateTime.utc(today.year, today.month);

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

  TransactionDraft draft({
    TransactionType type = TransactionType.expense,
    int paise = 85000,
    String? category = 'food',
    DateTime? date,
  }) => TransactionDraft(
    groupId: groupId,
    type: type,
    amountPaise: paise,
    category: category,
    date: date ?? today,
  );

  setUpAll(() async {
    if (_skip != null) return;
    admin = SupabaseClient(
      _url!,
      _service!,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    for (final role in ['mem', 'ga']) {
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
        .insert({'name': 'Live Tx $run'})
        .select('id')
        .single();
    groupId = group['id'] as String;
    await admin.from('group_members').insert([
      {'group_id': groupId, 'user_id': ids['mem'], 'group_role': 'MEMBER'},
      {'group_id': groupId, 'user_id': ids['ga'], 'group_role': 'GROUP_ADMIN'},
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

  test('member: categories, idempotent add, Other, paging, totals', () async {
    final client = await clientAs('mem');
    final txs = SupabaseTransactionsRepository(client);
    final cats = SupabaseCategoriesRepository(client);

    final expenseCats = await cats.list(groupId, type: TransactionType.expense);
    expect(expenseCats.first.name, 'Food');
    expect(expenseCats, hasLength(8));

    // Idempotent add: same client id twice -> one row.
    final id = const Uuid().v4();
    final first = await txs.add(draft(), id: id);
    final retry = await txs.add(draft(), id: id);
    expect(first.id, id);
    expect(first.category, 'Food', reason: 'canonical category name');
    expect(first.amountPaise, 85000);
    expect(retry.id, id);

    // "Other" category is created for this group.
    await txs.add(draft(category: 'Pets', paise: 30050));
    final after = await cats.list(groupId, type: TransactionType.expense);
    expect(after.map((c) => c.name), contains('Pets'));

    // Backdated income without category.
    await txs.add(
      draft(
        type: TransactionType.income,
        category: null,
        paise: 2000000,
        date: today.subtract(const Duration(days: 40)),
      ),
    );

    // More expenses for paging: total expenses this month = 5.
    for (final paise in [100, 200, 300]) {
      await txs.add(draft(paise: paise));
    }
    final filter = TransactionFilter(
      groupId: groupId,
      type: TransactionType.expense,
      from: monthStart,
      to: today,
    );
    final seen = <String>{};
    TransactionCursor? cursor;
    var pages = 0;
    while (true) {
      final page = await txs.list(filter, after: cursor, limit: 2);
      pages++;
      seen.addAll(page.items.map((t) => t.id));
      if (!page.hasMore) break;
      cursor = TransactionCursor.after(page.items.last);
    }
    expect(seen, hasLength(5));
    expect(pages, 3);

    expect(await txs.total(filter), 85000 + 30050 + 100 + 200 + 300);
    expect(
      await txs.total(
        TransactionFilter(
          groupId: groupId,
          type: TransactionType.expense,
          from: monthStart,
          to: today,
          category: 'pets',
        ),
      ),
      30050,
    );

    // Amount filter.
    final big = await txs.list(
      TransactionFilter(
        groupId: groupId,
        type: TransactionType.expense,
        minPaise: 30000,
      ),
    );
    expect(big.items.map((t) => t.amountPaise).toSet(), {85000, 30050});

    // Future date rejected.
    await expectLater(
      txs.add(draft(date: today.add(const Duration(days: 1)))),
      throwsA(isA<ValidationFailure>()),
    );

    // Decision 16: members edit/delete only entries they added.
    final byAdmin = await SupabaseTransactionsRepository(await clientAs('ga'))
        .add(draft(paise: 4200));
    expect((await txs.history(byAdmin.id)).canEdit, isFalse);
    await expectLater(
      txs.update(byAdmin.id, draft(paise: 1), expectedVersion: 1),
      throwsA(isA<PermissionFailure>()),
    );
    await expectLater(
      txs.delete(byAdmin.id, expectedVersion: 1),
      throwsA(isA<PermissionFailure>()),
    );

    final mine = await txs.add(draft(paise: 7700));
    final history = await txs.history(mine.id);
    expect(history.canEdit, isTrue);
    expect(history.created?.name, isNotNull);
    final edited = await txs.update(
      mine.id,
      draft(paise: 7800),
      expectedVersion: mine.syncVersion,
    );
    expect(edited.amountPaise, 7800);
    expect((await txs.history(mine.id)).updated?.name, history.created?.name);
    await txs.delete(mine.id, expectedVersion: edited.syncVersion);
    final lookup = await txs.findById(mine.id);
    expect(lookup, isA<TransactionDeleted>());
  }, skip: _skip);

  test('group admin: edit with version check, delete, categories', () async {
    final client = await clientAs('ga');
    final txs = SupabaseTransactionsRepository(client);
    final cats = SupabaseCategoriesRepository(client);

    final created = await txs.add(draft(paise: 50000, category: 'Rent'));
    final edited = await txs.update(
      created.id,
      draft(paise: 55000, category: 'Rent'),
      expectedVersion: created.syncVersion,
    );
    expect(edited.amountPaise, 55000);
    expect(edited.syncVersion, created.syncVersion + 1);

    await expectLater(
      txs.update(
        created.id,
        draft(paise: 1),
        expectedVersion: created.syncVersion, // stale
      ),
      throwsA(isA<RuleFailure>().having((f) => f.code, 'code', 'CONFLICT')),
    );

    await txs.delete(created.id, expectedVersion: edited.syncVersion);
    final page = await txs.list(TransactionFilter(groupId: groupId));
    expect(page.items.any((t) => t.id == created.id), isFalse);

    // Category rename cascades; delete hides it but keeps history.
    final pets = (await cats.list(
      groupId,
      type: TransactionType.expense,
    )).firstWhere((c) => c.name == 'Pets');
    await cats.rename(pets.id, 'Animals');
    final renamed = await txs.list(
      TransactionFilter(groupId: groupId, category: 'Animals'),
    );
    expect(renamed.items, hasLength(1));
    await cats.delete(pets.id);
    final active = await cats.list(groupId, type: TransactionType.expense);
    expect(active.map((c) => c.name), isNot(contains('Animals')));
    final all = await cats.list(
      groupId,
      type: TransactionType.expense,
      includeInactive: true,
    );
    expect(all.map((c) => c.name), contains('Animals'));
  }, skip: _skip);
}
