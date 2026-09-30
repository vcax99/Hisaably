import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/env.dart';
import 'core/network/supabase_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('en_IN');
  final prefs = await SharedPreferences.getInstance();

  if (Env.isConfigured) {
    // Session persistence and automatic token refresh are handled by
    // supabase_flutter.
    await Supabase.initialize(
      url: Env.supabaseUrl,
      publishableKey: Env.supabasePublishableKey,
    );
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
