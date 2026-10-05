import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/env.dart';
import 'core/network/network_status.dart';
import 'core/network/supabase_providers.dart';
import 'core/push/push_service.dart';
import 'core/sync/background_sync.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('en_IN');
  final prefs = await SharedPreferences.getInstance();

  if (Env.isConfigured) {
    // Session persistence and automatic token refresh are handled by
    // supabase_flutter.
    await NetworkStatus.instance.start();
    await Supabase.initialize(
      url: Env.supabaseUrl,
      publishableKey: Env.supabasePublishableKey,
      // Fails fast with no network instead of waiting for DNS timeouts.
      httpClient: OfflineAwareClient(),
      // postgrest's built-in retry (3× with 1s/2s/4s waits) would hold every
      // offline read ~7s before the app can fall back to local data. Retries
      // are the app's job: outbox backoff, pull-to-refresh, "Try again".
      postgrestOptions: const PostgrestClientOptions(retryEnabled: false),
    );
    // Android push (FCM); a no-op on iOS and without Firebase config.
    await PushService.initFirebase();
    // Best-effort background sync window (no await on the OS scheduling).
    unawaited(registerBackgroundSync());
  } else {
    debugPrint(
      'Supabase is not configured. Run with '
      '--dart-define-from-file=env/dev.json (see env/example.json).',
    );
  }

  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const HisaablyApp(),
    ),
  );
}
