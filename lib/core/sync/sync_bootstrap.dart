import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/application/session_controller.dart';
import '../../features/groups/data/groups_repository.dart';
import '../../features/transactions/application/transactions_providers.dart';
import '../../features/transactions/data/transactions_repository.dart';
import '../../features/transactions/domain/transaction.dart';
import '../config/env.dart';
import '../database/app_database.dart';
import '../network/network_status.dart';
import '../push/push_bootstrap.dart';
import '../utils/ist_date.dart';
import 'outbox_processor.dart';
import 'sync_engine.dart';
import '../network/supabase_providers.dart';

/// Local data belongs to one signed-in user on this device.
const localOwnerKey = 'local.owner_user_id';

/// Whether the local database/sync runs (off in widget tests, where Supabase
/// isn't configured and fakes replace the repositories; tests may override).
final localSyncEnabledProvider = Provider<bool>((ref) => Env.isConfigured);

/// Called when a session is (re)established: wipe local data that belongs to
/// a different user, then try to send anything queued.
Future<void> onSignedIn(WidgetRef ref, String userId) async {
  if (!ref.read(localSyncEnabledProvider)) return;
  try {
    final prefs = ref.read(sharedPreferencesProvider);
    final owner = prefs.getString(localOwnerKey);
    if (owner != null && owner != userId) {
      await ref.read(appDatabaseProvider).clearAll();
    }
    await prefs.setString(localOwnerKey, userId);
    unawaited(syncNow(ref, trigger: SyncTrigger.startup));
    unawaited(_warmCaches(ref));
    unawaited(registerPush(ref));
  } catch (e) {
    debugPrint('Local data bootstrap failed: ${e.runtimeType}');
  }
}

/// Loads what the app needs offline (groups, their categories, this month's
/// entries) into the local cache while the network is up.
Future<void> _warmCaches(WidgetRef ref) async {
  try {
    final groups = await ref.read(groupsRepositoryProvider).listGroups();
    final categories = ref.read(categoriesRepositoryProvider);
    final today = IstDate.today();
    await Future.wait([
      for (final g in groups)
        for (final type in TransactionType.values)
          categories.list(g.id, type: type),
      // This month's entries, so the Expense/Income lists open offline.
      ref
          .read(transactionsRepositoryProvider)
          .list(
            TransactionFilter(
              from: DateTime.utc(today.year, today.month),
              to: today,
            ),
            limit: 100,
          ),
    ]);
  } catch (e) {
    debugPrint('Cache warm-up skipped: ${e.runtimeType}');
  }
}

/// Tries to send queued writes (see [SyncTrigger]). Null when sync is off
/// or failed unexpectedly.
Future<FlushResult?> syncNow(
  WidgetRef ref, {
  SyncTrigger trigger = SyncTrigger.manual,
}) async {
  if (!ref.read(localSyncEnabledProvider)) return null;
  try {
    return await ref.read(syncEngineProvider).sync(trigger);
  } catch (e) {
    debugPrint('Sync failed: ${e.runtimeType}');
    return null;
  }
}

/// App lifecycle → engine (timers only run in the foreground).
void syncOnPause(WidgetRef ref) {
  if (ref.read(localSyncEnabledProvider)) ref.read(syncEngineProvider).paused();
}

Future<void> syncOnResume(WidgetRef ref) async {
  if (!ref.read(localSyncEnabledProvider)) return;
  try {
    await ref.read(syncEngineProvider).resumed();
  } catch (e) {
    debugPrint('Sync failed: ${e.runtimeType}');
  }
}

/// Number of unsynced writes (0 when local sync is off).
Future<int> unsyncedCount(WidgetRef ref) async {
  if (!ref.read(localSyncEnabledProvider)) return 0;
  try {
    return await ref.read(outboxProcessorProvider).unsyncedCount();
  } catch (_) {
    return 0;
  }
}

/// Explicit sign-out: wipe this device's local copy (cache + queue).
Future<void> clearLocalData(WidgetRef ref) async {
  if (!ref.read(localSyncEnabledProvider)) return;
  try {
    await ref.read(appDatabaseProvider).clearAll();
    await ref.read(sharedPreferencesProvider).remove(localOwnerKey);
  } catch (e) {
    debugPrint('Clearing local data failed: ${e.runtimeType}');
  }
}

/// Keeps lists/dashboards fresh when queued writes finish syncing.
void listenToSyncResults(WidgetRef ref) {
  if (!ref.read(localSyncEnabledProvider)) return;
  ref.listen(sessionControllerProvider, (_, next) {
    final session = next.value;
    if (session is SessionSignedIn) {
      unawaited(onSignedIn(ref, session.context.profile.id));
    }
  });
}

/// Sends queued writes as soon as the device gets a network back.
StreamSubscription<void>? subscribeToNetworkRegained(WidgetRef ref) {
  if (!ref.read(localSyncEnabledProvider)) return null;
  return NetworkStatus.instance.changes.where((online) => online).listen((_) {
    unawaited(syncNow(ref, trigger: SyncTrigger.networkRegained));
  });
}

/// Subscribes [onResult] to outbox results; returns a cancel callback.
StreamSubscription<void>? subscribeToSyncResults(WidgetRef ref) {
  if (!ref.read(localSyncEnabledProvider)) return null;
  try {
    return ref
        .read(outboxProcessorProvider)
        .results
        .listen((_) => invalidateTransactions(ref));
  } catch (_) {
    return null;
  }
}
