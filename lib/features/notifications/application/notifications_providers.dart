import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/notifications_repository.dart';
import '../domain/app_notification.dart';

class NotificationListState {
  const NotificationListState({
    required this.items,
    required this.hasMore,
    this.loadingMore = false,
    this.cachedAt,
  });

  final List<AppNotification> items;
  final bool hasMore;
  final bool loadingMore;
  final DateTime? cachedAt;

  NotificationListState copyWith({
    List<AppNotification>? items,
    bool? hasMore,
    bool? loadingMore,
  }) => NotificationListState(
    items: items ?? this.items,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
    cachedAt: cachedAt,
  );
}

/// Newest first, keyset-paged on demand.
class NotificationListController extends AsyncNotifier<NotificationListState> {
  static const pageSize = 30;

  @override
  Future<NotificationListState> build() async {
    final page = await ref
        .watch(notificationsRepositoryProvider)
        .list(limit: pageSize);
    return NotificationListState(
      items: page.items,
      hasMore: page.hasMore,
      cachedAt: page.cachedAt,
    );
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) return;
    if (current.items.isEmpty) return;
    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final page = await ref
          .read(notificationsRepositoryProvider)
          .list(
            after: NotificationCursor.after(current.items.last),
            limit: pageSize,
          );
      state = AsyncData(
        current.copyWith(
          items: [...current.items, ...page.items],
          hasMore: page.hasMore,
          loadingMore: false,
        ),
      );
    } catch (_) {
      state = AsyncData(current.copyWith(loadingMore: false));
    }
  }

  /// Optimistic: the dot disappears at once; the server call follows.
  Future<void> markRead(String id) async {
    final current = state.value;
    if (current != null) {
      state = AsyncData(
        current.copyWith(
          items: [
            for (final n in current.items) n.id == id ? n.markedRead() : n,
          ],
        ),
      );
    }
    await ref.read(notificationsRepositoryProvider).markRead(id);
    ref.invalidate(unreadNotificationsProvider);
  }

  Future<void> markAllRead() async {
    await ref.read(notificationsRepositoryProvider).markAllRead();
    final current = state.value;
    if (current != null) {
      state = AsyncData(
        current.copyWith(
          items: [for (final n in current.items) n.markedRead()],
        ),
      );
    }
    ref.invalidate(unreadNotificationsProvider);
  }

  Future<void> deleteAll() async {
    await ref.read(notificationsRepositoryProvider).deleteAll();
    state = const AsyncData(NotificationListState(items: [], hasMore: false));
    ref.invalidate(unreadNotificationsProvider);
  }
}

final notificationListProvider =
    AsyncNotifierProvider.autoDispose<
      NotificationListController,
      NotificationListState
    >(NotificationListController.new);

/// Unread badge on the bell. 0 when it can't be loaded (e.g. offline).
final unreadNotificationsProvider = FutureProvider.autoDispose<int>((
  ref,
) async {
  try {
    return await ref.watch(notificationsRepositoryProvider).unreadCount();
  } catch (_) {
    return 0;
  }
});

/// Auto-delete setting for read notifications: 7, 15, or null (never).
final notificationRetentionProvider = FutureProvider.autoDispose<int?>(
  (ref) => ref.watch(notificationsRepositoryProvider).retentionDays(),
);
