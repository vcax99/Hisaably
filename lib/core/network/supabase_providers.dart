import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';

/// The Supabase client. Only repositories/data sources may use it; widgets
/// must never call Supabase directly.
final supabaseClientProvider = Provider<SupabaseClient>((ref) {
  if (!Env.isConfigured) {
    throw StateError(
      'Supabase is not configured. Run with '
      '--dart-define-from-file=env/dev.json',
    );
  }
  return Supabase.instance.client;
});

/// Overridden in main() with the real instance (and in tests with a mock).
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPreferencesProvider not overridden'),
);
