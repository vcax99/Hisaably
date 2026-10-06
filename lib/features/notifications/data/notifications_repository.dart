import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/error_mapper.dart';
import '../../../core/network/supabase_providers.dart';
import '../../../core/sync/cache_store.dart';
import '../domain/app_notification.dart';

/// The signed-in user's notifications. RLS limits rows to the recipient;
/// marking read goes through RPCs. Throws [AppFailure] on error.
abstract interface class NotificationsRepository {
  Future<NotificationPage> list({NotificationCursor? after, int limit});

  Future<int> unreadCount();

  Future<void> markRead(String id);

  Future<void> markAllRead();

  /// Permanently deletes all of this user's notifications.
  Future<void> deleteAll();

  /// Days after reading before a notification is deleted; null = never.
  Future<int?> retentionDays();

  Future<void> setRetentionDays(int? days);
}

class SupabaseNotificationsRepository implements NotificationsRepository {
  SupabaseNotificationsRepository(this._client, [this._cache]);

  final SupabaseClient _client;
  final CacheStore? _cache;

  static const _firstPageKey = 'notifications.first';

  static const _columns =
      'id, group_id, transaction_id, type, title, body, is_read, created_at';

  Future<List<Map<String, dynamic>>> _fetch(
    NotificationCursor? after,
    int limit,
  ) async {
    var query = _client.rest.from('notifications').select(_columns);
    if (after != null) {
      final at = after.createdAt.toUtc().toIso8601String();
      query = query.or(
        'created_at.lt.$at,and(created_at.eq.$at,id.lt.${after.id})',
      );
    }
    final rows = await query
        .order('created_at', ascending: false)
        .order('id', ascending: false)
        .limit(limit + 1);
    return rows;
  }

  NotificationPage _page(Object? raw, int limit, DateTime? cachedAt) {
    final rows = [
      for (final r in raw! as List)
        AppNotification.fromJson((r as Map).cast<String, dynamic>()),
    ];
    final hasMore = rows.length > limit;
    return NotificationPage(
      hasMore ? rows.sublist(0, limit) : rows,
      hasMore: hasMore,
      cachedAt: cachedAt,
    );
  }

  @override
  Future<NotificationPage> list({NotificationCursor? after, int limit = 30}) {
    if (after != null) {
      return _guard(() async => _page(await _fetch(after, limit), limit, null));
    }
    // First page: cached for offline viewing.
    return fetchWithCache(
      _cache,
      _firstPageKey,
      () => _fetch(null, limit),
      (raw, cachedAt) => _page(raw, limit, cachedAt),
    );
  }

  @override
  Future<int> unreadCount() => _guard(() async {
    final res = await _client.rest
        .from('notifications')
        .select('id')
        .eq('is_read', false)
        .count(CountOption.exact);
    return res.count;
  });

  @override
  Future<void> markRead(String id) => _guard(
    () => _client.rpc<void>(
      'mark_notification_read',
      params: {'p_notification_id': id},
    ),
  );

  @override
  Future<void> markAllRead() =>
      _guard(() => _client.rpc<void>('mark_all_notifications_read'));

  @override
  Future<void> deleteAll() => _guard(() async {
    await _client.rpc<int>('delete_all_notifications');
    // The offline copy of the first page must not bring them back.
    await _cache?.put(_firstPageKey, const <Object>[]);
  });

  @override
  Future<int?> retentionDays() => _guard(() async {
    final json = await _client.rpc<Map<String, dynamic>>(
      'get_notification_settings',
    );
    return (json['retention_days'] as num?)?.toInt();
  });

  @override
  Future<void> setRetentionDays(int? days) => _guard(
    () => _client.rpc<Map<String, dynamic>>(
      'set_notification_retention',
      params: {'p_days': days},
    ),
  );

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e, st) {
      throw mapError(e, st);
    }
  }
}

final notificationsRepositoryProvider = Provider<NotificationsRepository>(
  (ref) => SupabaseNotificationsRepository(
    ref.watch(supabaseClientProvider),
    ref.watch(cacheStoreProvider),
  ),
);
