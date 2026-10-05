import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_failure.dart';

/// Converts any exception from Supabase / network code into a user-safe
/// [AppFailure]. Technical details are logged (debug only), never shown.
AppFailure mapError(Object error, [StackTrace? stackTrace]) {
  if (error is AppFailure) return error;

  final failure = switch (error) {
    AuthException() => _mapAuth(error),
    PostgrestException() => _mapPostgrest(error),
    FunctionException() => _mapFunction(error),
    SocketException() ||
    TimeoutException() ||
    HttpException() => const NetworkFailure(),
    _ when _looksLikeNetwork(error) => const NetworkFailure(),
    _ => const UnexpectedFailure(),
  };

  if (failure is UnexpectedFailure) {
    // Diagnostic only — never includes tokens (Supabase exceptions don't
    // carry them) and never reaches the UI.
    debugPrint('Unexpected error: ${error.runtimeType}: $error');
  }
  return failure;
}

bool _looksLikeNetwork(Object error) {
  final text = error.toString();
  return text.contains('ClientException') ||
      text.contains('SocketException') ||
      text.contains('Failed host lookup') ||
      text.contains('Connection refused') ||
      text.contains('Connection closed');
}

AppFailure _mapAuth(AuthException e) {
  if (e is AuthRetryableFetchException) return const NetworkFailure();
  switch (e.code) {
    case 'invalid_credentials':
      return const AuthFailure();
    case 'user_banned':
      return const AccountDisabledFailure();
    case 'session_not_found' ||
        'session_expired' ||
        'refresh_token_not_found' ||
        'refresh_token_already_used' ||
        'bad_jwt':
      return const SessionExpiredFailure();
  }
  final msg = e.message.toLowerCase();
  if (msg.contains('invalid login credentials')) return const AuthFailure();
  if (msg.contains('banned')) return const AccountDisabledFailure();
  if (e.statusCode == '401') return const SessionExpiredFailure();
  return const UnexpectedFailure();
}

/// App RPCs raise errors with a machine-readable code in HINT (docs/BACKEND.md).
AppFailure _mapPostgrest(PostgrestException e) {
  final message = e.message;
  switch (e.hint) {
    case 'NOT_AUTHENTICATED':
      return const SessionExpiredFailure();
    case 'ACCOUNT_DISABLED':
      return const AccountDisabledFailure();
    case 'FORBIDDEN':
      return PermissionFailure(message);
    case 'NOT_FOUND':
      return NotFoundFailure(message);
    case 'VALIDATION' || 'FUTURE_DATE':
      return ValidationFailure(message);
    case final String code when code.isNotEmpty && code == code.toUpperCase():
      return RuleFailure(code, message);
  }
  // Raw Postgres/PostgREST errors: never show their text.
  if (e.code == '42501' || e.code == 'PGRST301') {
    return const PermissionFailure();
  }
  // `.single()` on zero rows (e.g. the record was deleted meanwhile).
  if (e.code == 'PGRST116') return const NotFoundFailure();
  if (e.code == 'PGRST303' || e.code == 'PGRST302') {
    return const SessionExpiredFailure();
  }
  return const UnexpectedFailure();
}

/// admin-users Edge Function returns `{error: {code, message}}`.
AppFailure _mapFunction(FunctionException e) {
  final details = e.details;
  String? code;
  String? message;
  if (details is Map && details['error'] is Map) {
    final err = details['error'] as Map;
    code = err['code'] as String?;
    message = err['message'] as String?;
  }
  message ??= 'Something went wrong. Please try again.';
  return switch (code) {
    'NOT_AUTHENTICATED' => const SessionExpiredFailure(),
    'ACCOUNT_DISABLED' => const AccountDisabledFailure(),
    'FORBIDDEN' => PermissionFailure(message),
    'NOT_FOUND' => NotFoundFailure(message),
    'VALIDATION' => ValidationFailure(message),
    'UNEXPECTED' || null => const UnexpectedFailure(),
    final String c => RuleFailure(c, message),
  };
}
