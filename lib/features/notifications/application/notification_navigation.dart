import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/widgets/root_messenger.dart';
import '../../../routing/app_router.dart';
import '../../../routing/routes.dart';
import '../../auth/application/session_controller.dart';
import '../../groups/application/groups_providers.dart';
import '../../transactions/data/transactions_repository.dart';
import '../../transactions/domain/transaction.dart';
import '../../transactions/presentation/transactions_view.dart';
import '../data/notifications_repository.dart';
import '../domain/app_notification.dart';
import 'notifications_providers.dart';

/// Opens what a notification is about (tapped in the list or from a push):
/// an expense/income → its tab + the entry's details; a monthly one → the
/// Dashboard. A deleted or no-longer-visible entry shows a message instead.
Future<void> openNotificationTarget(
  WidgetRef ref, {
  required NotificationType type,
  String? transactionId,
  String? notificationId,
}) async {
  if (notificationId != null && notificationId.isNotEmpty) {
    try {
      await ref.read(notificationsRepositoryProvider).markRead(notificationId);
    } catch (_) {
      // Best effort (offline): it stays unread.
    }
    ref
      ..invalidate(unreadNotificationsProvider)
      ..invalidate(notificationListProvider);
  }

  final router = ref.read(appRouterProvider);
  final isSuperAdmin =
      ref.read(currentUserContextProvider)?.profile.isSuperAdmin ?? false;

  switch (type) {
    case NotificationType.monthStarted:
    case NotificationType.monthlySummary:
      router.go(isSuperAdmin ? Routes.adminDashboard : Routes.memberDashboard);
      return;
    case NotificationType.expenseAdded:
    case NotificationType.incomeAdded:
      break;
  }

  final noun = type == NotificationType.expenseAdded ? 'expense' : 'income';
  if (transactionId == null || transactionId.isEmpty) {
    // The server unlinks notifications when their entry is deleted.
    _toast('This $noun has been deleted.');
    return;
  }

  final TransactionLookup lookup;
  try {
    lookup = await ref
        .read(transactionsRepositoryProvider)
        .findById(transactionId);
  } on NetworkFailure {
    _toast('You are offline. Connect to the internet to open this $noun.');
    return;
  } catch (_) {
    _toast('Couldn\'t open this $noun. Please try again.');
    return;
  }

  switch (lookup) {
    case TransactionDeleted(:final type):
      _toast('This ${type.label.toLowerCase()} has been deleted.');
    case TransactionUnavailable():
      _toast('This $noun is no longer available to you.');
    case TransactionFound(:final transaction):
      router.go(
        isSuperAdmin
            ? Routes.adminGroup(transaction.groupId)
            : transaction.isExpense
            ? Routes.memberExpenses
            : Routes.memberIncome,
      );
      String? groupName;
      try {
        final groups = await ref.read(groupsListProvider.future);
        groupName = groups
            .where((g) => g.id == transaction.groupId)
            .firstOrNull
            ?.name;
      } catch (_) {}
      await WidgetsBinding.instance.endOfFrame;
      final context = router.routerDelegate.navigatorKey.currentContext;
      if (context != null && context.mounted) {
        await showTransactionDetails(
          context,
          transaction,
          groupName: groupName,
        );
      }
  }
}

void _toast(String message) {
  rootScaffoldMessengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
