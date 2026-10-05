import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/notifications/application/notification_navigation.dart';
import '../../features/notifications/application/notifications_providers.dart';
import '../../features/notifications/domain/app_notification.dart';
import '../../features/transactions/application/transactions_providers.dart';
import '../widgets/root_messenger.dart';
import 'push_service.dart';

/// Registers this device for push after sign-in (Android only).
Future<void> registerPush(WidgetRef ref) async {
  if (!PushService.supported) return;

  // Someone else's entry changed the group's numbers: refresh everything
  // that shows them, plus the notification views.
  void refresh() {
    invalidateTransactions(ref);
    ref
      ..invalidate(unreadNotificationsProvider)
      ..invalidate(notificationListProvider);
  }

  Future<void> open(RemoteMessage m) => openNotificationTarget(
    ref,
    type: NotificationType.fromWire(m.data['type'] as String? ?? ''),
    transactionId: m.data['transaction_id'] as String?,
    notificationId: m.data['notification_id'] as String?,
  );

  await ref
      .read(pushServiceProvider)
      .register(
        // In the foreground Android doesn't show the system banner.
        onForeground: (RemoteMessage m) {
          refresh();
          final n = m.notification;
          if (n == null) return;
          rootScaffoldMessengerKey.currentState?.showSnackBar(
            SnackBar(
              content: Text([n.title, n.body].whereType<String>().join(' — ')),
              // With an action Flutter would keep it until dismissed.
              persist: false,
              duration: const Duration(seconds: 5),
              action: SnackBarAction(label: 'View', onPressed: () => open(m)),
            ),
          );
        },
        // Tapped in the system tray.
        onOpened: (RemoteMessage m) {
          refresh();
          open(m);
        },
      );
}

/// Before sign-out.
Future<void> unregisterPush(WidgetRef ref) async {
  if (!PushService.supported) return;
  await ref.read(pushServiceProvider).unregister();
}
