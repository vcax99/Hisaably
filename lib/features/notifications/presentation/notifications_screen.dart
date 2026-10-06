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
import '../data/notifications_repository.dart';
import '../domain/app_notification.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(notificationListProvider);
    final items = list.value?.items ?? const <AppNotification>[];
    final hasUnread = items.any((n) => !n.isRead);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          PopupMenuButton<_MenuAction>(
            key: const Key('notifications-menu'),
            tooltip: 'More',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (action) => switch (action) {
              _MenuAction.markAllRead => runAction(
                context,
                () => ref.read(notificationListProvider.notifier).markAllRead(),
                successMessage: 'All notifications marked as read',
              ),
              _MenuAction.deleteAll => _deleteAll(context, ref),
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                key: const Key('mark-all-read'),
                value: _MenuAction.markAllRead,
                enabled: hasUnread,
                child: const ListTile(
                  leading: Icon(Icons.done_all_rounded),
                  title: Text('Mark all as read'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                key: const Key('delete-all'),
                value: _MenuAction.deleteAll,
                enabled: items.isNotEmpty,
                child: const ListTile(
                  leading: Icon(
                    Icons.delete_sweep_outlined,
                    color: AppColors.expense,
                  ),
                  title: Text('Delete all'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
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
                const _RetentionRow(),
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

enum _MenuAction { markAllRead, deleteAll }

Future<void> _deleteAll(BuildContext context, WidgetRef ref) async {
  final confirmed = await showConfirmDialog(
    context,
    title: 'Delete all notifications?',
    message:
        'All your notifications, read and unread, will be deleted '
        'permanently. Entries in your group are not affected.',
    confirmLabel: 'Delete all',
    destructive: true,
  );
  if (!confirmed || !context.mounted) return;
  await runAction(
    context,
    () => ref.read(notificationListProvider.notifier).deleteAll(),
    successMessage: 'Notifications deleted',
  );
}

/// "Auto-delete read notifications: Never / After 7 days / After 15 days".
class _RetentionRow extends ConsumerWidget {
  const _RetentionRow();

  static const _never = 0; // dropdown value for "never" (null on the server)
  static const _options = {
    _never: 'Never',
    7: 'After 7 days',
    15: 'After 15 days',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final retention = ref.watch(notificationRetentionProvider);
    final textTheme = Theme.of(context).textTheme;
    // Offline or not loaded yet: the setting lives on the server.
    if (!retention.hasValue) return const SizedBox.shrink();
    final current = retention.value ?? _never;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.sm,
        AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.auto_delete_outlined, color: AppColors.textMuted),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              'Auto-delete read notifications',
              style: textTheme.bodyMedium,
            ),
          ),
          DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              key: const Key('retention-dropdown'),
              value: _options.containsKey(current) ? current : _never,
              dropdownColor: AppColors.elevated,
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              style: textTheme.bodyLarge,
              items: [
                for (final MapEntry(:key, :value) in _options.entries)
                  DropdownMenuItem(value: key, child: Text(value)),
              ],
              onChanged: (days) async {
                if (days == null || days == current) return;
                final ok = await runAction(
                  context,
                  () => ref
                      .read(notificationsRepositoryProvider)
                      .setRetentionDays(days == _never ? null : days),
                  successMessage: days == _never
                      ? 'Read notifications will be kept'
                      : 'Read notifications will be deleted '
                            '${_options[days]!.toLowerCase()}',
                );
                if (ok) ref.invalidate(notificationRetentionProvider);
              },
            ),
          ),
        ],
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
