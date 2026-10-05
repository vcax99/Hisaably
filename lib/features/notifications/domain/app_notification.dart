/// An in-app notification for the signed-in user (server-created after a
/// committed write, never for the actor).
class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.isRead,
    required this.createdAt,
    this.groupId,
    this.transactionId,
  });

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
    id: j['id'] as String,
    groupId: j['group_id'] as String?,
    transactionId: j['transaction_id'] as String?,
    type: NotificationType.fromWire(j['type'] as String),
    title: j['title'] as String,
    body: j['body'] as String,
    isRead: j['is_read'] as bool? ?? false,
    createdAt: DateTime.parse(j['created_at'] as String).toUtc(),
  );

  final String id;
  final String? groupId;
  final String? transactionId;
  final NotificationType type;
  final String title;
  final String body;
  final bool isRead;
  final DateTime createdAt;

  AppNotification markedRead() => AppNotification(
    id: id,
    groupId: groupId,
    transactionId: transactionId,
    type: type,
    title: title,
    body: body,
    isRead: true,
    createdAt: createdAt,
  );
}

enum NotificationType {
  expenseAdded('EXPENSE_ADDED'),
  incomeAdded('INCOME_ADDED'),
  monthStarted('MONTH_STARTED'),
  monthlySummary('MONTHLY_SUMMARY');

  const NotificationType(this.wire);
  final String wire;

  static NotificationType fromWire(String w) =>
      values.firstWhere((t) => t.wire == w, orElse: () => monthlySummary);
}

/// Keyset cursor: newest first by (created_at, id).
class NotificationCursor {
  const NotificationCursor(this.createdAt, this.id);

  factory NotificationCursor.after(AppNotification n) =>
      NotificationCursor(n.createdAt, n.id);

  final DateTime createdAt;
  final String id;
}

class NotificationPage {
  const NotificationPage(this.items, {required this.hasMore, this.cachedAt});

  final List<AppNotification> items;
  final bool hasMore;

  /// Set when the first page came from the offline cache.
  final DateTime? cachedAt;
}
