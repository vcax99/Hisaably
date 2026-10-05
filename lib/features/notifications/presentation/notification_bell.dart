import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/env.dart';
import '../../../routing/routes.dart';
import '../application/notifications_providers.dart';

class NotificationBell extends ConsumerWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // No backend in widget tests: plain bell.
    final unread = Env.isConfigured
        ? ref.watch(unreadNotificationsProvider).value ?? 0
        : 0;
    return IconButton(
      tooltip: 'Notifications',
      icon: Badge(
        key: const Key('unread-badge'),
        isLabelVisible: unread > 0,
        label: Text(unread > 99 ? '99+' : '$unread'),
        child: const Icon(Icons.notifications_none_rounded),
      ),
      onPressed: () async {
        await context.push(Routes.notifications);
        ref.invalidate(unreadNotificationsProvider);
      },
    );
  }
}
