/// User-safe failures. Repositories convert technical exceptions
/// (Supabase, Postgres, network, SQLite) into one of these so raw database
/// errors never reach the UI.
sealed class AppFailure implements Exception {
  const AppFailure(this.message);

  /// Message that is safe to show to the user.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

class NetworkFailure extends AppFailure {
  const NetworkFailure([
    super.message = 'You appear to be offline. Please check your connection.',
  ]);
}

class AuthFailure extends AppFailure {
  const AuthFailure([super.message = 'Incorrect username or password.']);
}

class SessionExpiredFailure extends AppFailure {
  const SessionExpiredFailure([
    super.message = 'Your session has expired. Please sign in again.',
  ]);
}

class AccountDisabledFailure extends AppFailure {
  const AccountDisabledFailure([
    super.message =
        'Your account has been disabled. Please contact the administrator.',
  ]);
}

class PermissionFailure extends AppFailure {
  const PermissionFailure([
    super.message = 'You do not have permission to do this.',
  ]);
}

class ValidationFailure extends AppFailure {
  const ValidationFailure(super.message);
}

class NotFoundFailure extends AppFailure {
  const NotFoundFailure([super.message = 'The item could not be found.']);
}

/// Business-rule rejection with a server code, e.g. GROUP_MEMBER_LIMIT,
/// ALREADY_MEMBER, CONFLICT, USERNAME_TAKEN. [message] is user-safe.
class RuleFailure extends AppFailure {
  const RuleFailure(this.code, super.message);

  final String code;
}

class UnexpectedFailure extends AppFailure {
  const UnexpectedFailure([
    super.message = 'Something went wrong. Please try again.',
  ]);
}
