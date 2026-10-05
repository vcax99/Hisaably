import 'package:hisaably/core/errors/app_failure.dart';
import 'package:hisaably/features/notifications/data/notifications_repository.dart';
import 'package:hisaably/features/notifications/domain/app_notification.dart';

/// In-memory notifications for widget tests.
class FakeNotificationsRepository implements NotificationsRepository {
  FakeNotificationsRepository(this.items);

  final List<AppNotification> items;
  bool offline = false;
  final markedRead = <String>[];
  var markAllCalls = 0;

  @override
  Future<NotificationPage> list({
    NotificationCursor? after,
    int limit = 30,
  }) async {
    if (offline) throw const NetworkFailure();
    final start = after == null
        ? 0
        : items.indexWhere((n) => n.id == after.id) + 1;
    final page = items.skip(start).take(limit).toList();
    return NotificationPage(page, hasMore: start + limit < items.length);
  }

  @override
  Future<int> unreadCount() async => items.where((n) => !n.isRead).length;

  @override
  Future<void> markRead(String id) async => markedRead.add(id);

  @override
  Future<void> markAllRead() async => markAllCalls++;
}
