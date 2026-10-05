import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/sync/sync_banner.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/async_value_view.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/empty_state.dart';
import '../application/notification_navigation.dart';
import '../application/notifications_providers.dart';
import '../domain/app_notification.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(notificationListProvider);
    final hasUnread = list.value?.items.any((n) => !n.isRead) ?? false;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          if (hasUnread)
            TextButton(
              key: const Key('mark-all-read'),
              onPressed: () => runAction(
                context,
                () => ref.read(notificationListProvider.notifier).markAllRead(),
              ),
              child: const Text('Mark all read'),
            ),
        ],
      ),
      body: AsyncValueView(
        value: list,
        onRetry: () => ref.invalidate(notificationListProvider),
        data: (state) => RefreshIndicator(
          onRefresh: () async {
            ref
              ..invalidate(notificationListProvider)
              ..invalidate(unreadNotificationsProvider);
            await ref.read(notificationListProvider.future);
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.extentAfter < 400) {
                ref.read(notificationListProvider.notifier).loadMore();
              }
              return false;
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.xxl,
              ),
              children: [
                SyncBanner(cachedAt: state.cachedAt),
                if (state.items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: AppSpacing.xxl),
                    child: EmptyState(
                      icon: Icons.notifications_none_rounded,
                      title: 'No notifications yet',
                      message:
                          'You\'ll be told here when someone in your group '
                          'adds an expense or income, and when a new month '
                          'starts.',
                    ),
                  ),
                for (final n in state.items)
                  _NotificationTile(
                    notification: n,
                    onTap: () {
                      if (!n.isRead) {
                        ref
                            .read(notificationListProvider.notifier)
                            .markRead(n.id)
                            .catchError((_) {});
                      }
                      openNotificationTarget(
                        ref,
                        type: n.type,
                        transactionId: n.transactionId,
                      );
                    },
                  ),
                if (state.loadingMore)
                  const Padding(
                    padding: EdgeInsets.all(AppSpacing.lg),
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.notification, this.onTap});

  final AppNotification notification;
  final VoidCallback? onTap;

  static String _when(DateTime at) {
    final local = at.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    if (day == today) return DateFormat('h:mm a').format(local);
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return DateFormat(local.year == now.year ? 'd MMM' : 'd MMM yyyy')
        .format(local);
  }

  @override
  Widget build(BuildContext context) {
    final n = notification;
    final textTheme = Theme.of(context).textTheme;
    final (icon, color) = switch (n.type) {
      NotificationType.expenseAdded => (
        Icons.arrow_upward_rounded,
        AppColors.expense,
      ),
      NotificationType.incomeAdded => (
        Icons.arrow_downward_rounded,
        AppColors.income,
      ),
      _ => (Icons.calendar_month_rounded, AppColors.accent),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        minTileHeight: 64,
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.14),
          child: Icon(icon, color: color, size: 20),
        ),
        title: Text(
          n.title,
          style: n.isRead ? null : const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(n.body),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(_when(n.createdAt), style: textTheme.bodySmall),
            if (!n.isRead) ...[
              const SizedBox(height: AppSpacing.xs),
              Container(
                key: const Key('unread-dot'),
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
