/// Public client configuration, injected at build time with
/// `--dart-define-from-file=env/dev.json`.
///
/// Only public values belong here (Supabase URL + publishable key).
/// Server-side secrets (service-role key, Firebase service account) must
/// never be added to this class or to any env/*.json file.
abstract final class Env {
  static const appEnv = String.fromEnvironment('APP_ENV', defaultValue: 'dev');
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabasePublishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty &&
      supabasePublishableKey.isNotEmpty &&
      !supabaseUrl.contains('YOUR-PROJECT-REF');

  static bool get isProduction => appEnv == 'prod';
}
