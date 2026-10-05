// Live test: NotificationsRepository against dev — keyset paging through 65
// notifications (same-timestamp ties included), unread count, mark read,
// mark all read, and recipient isolation (RLS).
// Run with scripts/run_live_tests.sh.
@Tags(['live'])
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/features/auth/domain/username.dart';
import 'package:hisaably/features/notifications/data/notifications_repository.dart';
import 'package:hisaably/features/notifications/domain/app_notification.dart';
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
    for (final role in ['nme', 'nother']) {
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
    // 65 for "me": 5 share one timestamp (keyset tie-break on id),
    // microsecond timestamps with a '+00:00' offset in the cursor.
    final base = DateTime.utc(2026, 9, 1, 10);
    await admin.from('notifications').insert([
      for (var i = 0; i < 65; i++)
        {
          'recipient_id': ids['nme'],
          'type': 'MONTHLY_SUMMARY',
          'title': 'n$i',
          'body': 'live',
          'created_at':
              (i < 5 ? base : base.add(Duration(microseconds: i * 1001)))
                  .toIso8601String(),
        },
      {
        'recipient_id': ids['nother'],
        'type': 'MONTHLY_SUMMARY',
        'title': 'not yours',
        'body': 'live',
        // Bulk insert: every row needs the same keys (missing = null).
        'created_at': base.toIso8601String(),
      },
    ]);
  });

  tearDownAll(() async {
    if (_skip != null) return;
    for (final id in ids.values) {
      await admin.auth.admin.deleteUser(id); // notifications cascade
    }
  });

  test('keyset paging, unread count, mark read, isolation', () async {
    final repo = SupabaseNotificationsRepository(await clientAs('nme'));

    final seen = <String>[];
    NotificationCursor? after;
    var pages = 0;
    while (true) {
      final page = await repo.list(after: after, limit: 20);
      pages++;
      seen.addAll(page.items.map((n) => n.title));
      if (!page.hasMore) break;
      after = NotificationCursor.after(page.items.last);
    }
    expect(pages, 4);
    expect(seen, hasLength(65), reason: 'no gaps or repeats across pages');
    expect(seen.toSet(), hasLength(65));
    expect(seen, isNot(contains('not yours')));
    expect(seen.first, 'n64', reason: 'newest first');

    expect(await repo.unreadCount(), 65);
    final first = (await repo.list(limit: 1)).items.single;
    await repo.markRead(first.id);
    expect(await repo.unreadCount(), 64);
    await repo.markAllRead();
    expect(await repo.unreadCount(), 0);
    expect((await repo.list(limit: 5)).items.every((n) => n.isRead), isTrue);

    // Someone else's notification can't be marked (silently no-op) or seen.
    final other = await admin
        .from('notifications')
        .select('id')
        .eq('recipient_id', ids['nother']!)
        .single();
    await repo.markRead(other['id'] as String);
    final still = await admin
        .from('notifications')
        .select('is_read')
        .eq('id', other['id'] as String)
        .single();
    expect(still['is_read'], isFalse);
  }, skip: _skip);
}
