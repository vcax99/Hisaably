/// Users sign in with a username. Supabase Auth needs an email, so each
/// username maps to a synthetic, never-mailed address (see docs/BACKEND.md).
abstract final class Username {
  static const emailDomain = 'users.hisaably.invalid';

  static final _pattern = RegExp(r'^[a-z0-9]([a-z0-9._]{1,28})[a-z0-9]$');

  static String normalize(String input) => input.trim().toLowerCase();

  static bool isValid(String input) => _pattern.hasMatch(normalize(input));

  /// "Rahul " -> "rahul@users.hisaably.invalid".
  static String toAuthEmail(String input) => '${normalize(input)}@$emailDomain';
}
