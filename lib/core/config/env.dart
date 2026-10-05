/// Public client configuration, injected at build time with
/// `--dart-define-from-file=env/dev.json`.
///
/// Only public values belong here (Supabase URL + publishable key, and the
/// Firebase Android client identifiers, which are public by design).
/// Server-side secrets (service-role key, Firebase service account) must
/// never be added to this class or to any env/*.json file.
abstract final class Env {
  static const appEnv = String.fromEnvironment('APP_ENV', defaultValue: 'dev');
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabasePublishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );

  // Firebase (Android push only — see owner decision 14).
  static const firebaseProjectId = String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
  );
  static const firebaseSenderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static const firebaseAndroidAppId = String.fromEnvironment(
    'FIREBASE_ANDROID_APP_ID',
  );
  static const firebaseAndroidApiKey = String.fromEnvironment(
    'FIREBASE_ANDROID_API_KEY',
  );

  static bool get hasFirebase =>
      firebaseProjectId.isNotEmpty &&
      firebaseSenderId.isNotEmpty &&
      firebaseAndroidAppId.isNotEmpty &&
      firebaseAndroidApiKey.isNotEmpty;

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty &&
      supabasePublishableKey.isNotEmpty &&
      !supabaseUrl.contains('YOUR-PROJECT-REF');

  static bool get isProduction => appEnv == 'prod';
}
