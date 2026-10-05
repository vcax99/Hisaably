import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

import '../../features/transactions/data/transactions_repository.dart';
import '../config/env.dart';
import '../database/app_database.dart';
import '../network/network_status.dart';
import '../network/reachability.dart';
import 'outbox_processor.dart';
import 'sync_bootstrap.dart';
import 'transactions_local_data_source.dart';

/// Background "opportunity" sync (spec §22): Android WorkManager / iOS
/// BGTaskScheduler wake the app now and then, with a network. Best effort:
/// the OS decides when (iOS may never run it; nothing runs after a force
/// quit), so the app never promises it.
///
/// It NEVER refreshes the auth token: refresh tokens rotate, and a refresh
/// here could leave the (suspended) foreground app holding a stale one,
/// which Supabase may treat as reuse and revoke, signing the user out. It
/// uses the saved access token while still valid (≈1h after last use) and
/// otherwise leaves the queue for the next app open.
const backgroundSyncTask = 'com.bikash.hisaably.sync';

@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      final outcome = await runBackgroundSync();
      debugPrint('Background sync: $outcome');
    } catch (e) {
      debugPrint('Background sync failed: ${e.runtimeType}');
    }
    // Never ask the OS to retry: the next window or app open takes over.
    return true;
  });
}

/// Schedules the periodic task (Android ≥15 min; iOS: when it sees fit).
Future<void> registerBackgroundSync() async {
  if (kIsWeb ||
      !(defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS)) {
    return;
  }
  try {
    await Workmanager().initialize(backgroundSyncDispatcher);
    await Workmanager().registerPeriodicTask(
      backgroundSyncTask,
      backgroundSyncTask,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  } catch (e) {
    debugPrint('Background sync not available: ${e.runtimeType}');
  }
}

/// The signed-in user's saved session, as supabase_flutter persisted it.
@immutable
class PersistedSession {
  const PersistedSession(this.userId, this.accessToken, this.expiresAt);

  final String userId;
  final String accessToken;
  final DateTime expiresAt;

  /// Usable for a short background run (1 min safety margin).
  bool isValidAt(DateTime now) =>
      expiresAt.isAfter(now.add(const Duration(minutes: 1)));

  static PersistedSession? parse(String? json) {
    if (json == null) return null;
    try {
      final m = jsonDecode(json) as Map<String, dynamic>;
      final token = m['access_token'] as String?;
      final userId = (m['user'] as Map?)?['id'] as String?;
      final expiresAt = m['expires_at'] as int?;
      if (token == null || userId == null || expiresAt == null) return null;
      return PersistedSession(
        userId,
        token,
        DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000, isUtc: true),
      );
    } catch (_) {
      return null;
    }
  }
}

/// supabase_flutter's SharedPreferences key for the session.
String persistedSessionKey(String supabaseUrl) =>
    'sb-${Uri.parse(supabaseUrl).host.split('.').first}-auth-token';

/// Why a background run did or didn't sync (for logs and tests).
enum BackgroundSkip { notConfigured, noSession, tokenExpired, otherUser }

/// Checks that don't touch the database or network.
BackgroundSkip? backgroundPreconditions({
  required bool configured,
  required PersistedSession? session,
  required String? localOwner,
  required DateTime now,
}) {
  if (!configured) return BackgroundSkip.notConfigured;
  if (session == null) return BackgroundSkip.noSession;
  if (!session.isValidAt(now)) return BackgroundSkip.tokenExpired;
  // Local data must belong to the signed-in user (it's wiped on switch).
  if (localOwner != localOwnerId(session.userId)) {
    return BackgroundSkip.otherUser;
  }
  return null;
}

Future<String> runBackgroundSync() async {
  WidgetsFlutterBinding.ensureInitialized();
  // workmanager may run a due task inside the open app; the foreground sync
  // engine already handles that case.
  if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
    return 'app in foreground';
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final session = Env.isConfigured
      ? PersistedSession.parse(
          prefs.getString(persistedSessionKey(Env.supabaseUrl)),
        )
      : null;
  final skip = backgroundPreconditions(
    configured: Env.isConfigured,
    session: session,
    localOwner: prefs.getString(localOwnerKey),
    now: DateTime.now().toUtc(),
  );
  if (skip != null) return skip.name;

  final db = AppDatabase();
  final client = SupabaseClient(
    Env.supabaseUrl,
    Env.supabasePublishableKey,
    // Fixed token: no refresh in the background (see above).
    accessToken: () async => session!.accessToken,
    httpClient: OfflineAwareClient(),
    postgrestOptions: const PostgrestClientOptions(retryEnabled: false),
  );
  try {
    final local = TransactionsLocalDataSource(db);
    final outbox = OutboxProcessor(
      db,
      local,
      SupabaseTransactionsRepository(client).sendCreate,
    );
    if (await outbox.unsyncedCount() == 0) return 'nothing queued';
    await NetworkStatus.instance.start();
    if (!await Reachability().check()) return 'unreachable';
    final r = await outbox.flush(force: true);
    outbox.dispose();
    return 'synced ${r.synced}, failed ${r.failed}, offline ${r.offline}';
  } finally {
    await client.dispose();
    await db.close();
  }
}
