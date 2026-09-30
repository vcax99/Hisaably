import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/errors/app_failure.dart';
import 'package:hisaably/core/errors/error_mapper.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('auth errors', () {
    test('invalid credentials', () {
      expect(
        mapError(
          const AuthApiException(
            'Invalid login credentials',
            statusCode: '400',
            code: 'invalid_credentials',
          ),
        ),
        isA<AuthFailure>(),
      );
    });
    test('banned user -> disabled', () {
      expect(
        mapError(
          const AuthApiException(
            'User is banned',
            statusCode: '400',
            code: 'user_banned',
          ),
        ),
        isA<AccountDisabledFailure>(),
      );
    });
    test('retryable fetch -> network', () {
      expect(mapError(AuthRetryableFetchException()), isA<NetworkFailure>());
    });
  });

  group('RPC errors use the HINT code', () {
    PostgrestException rpc(
      String hint, [
      String message = 'Readable message',
    ]) => PostgrestException(message: message, code: 'P0001', hint: hint);

    test('known codes', () {
      expect(mapError(rpc('FORBIDDEN')), isA<PermissionFailure>());
      expect(mapError(rpc('ACCOUNT_DISABLED')), isA<AccountDisabledFailure>());
      expect(mapError(rpc('NOT_AUTHENTICATED')), isA<SessionExpiredFailure>());
      expect(mapError(rpc('NOT_FOUND')), isA<NotFoundFailure>());
      final v = mapError(
        rpc('FUTURE_DATE', 'Transaction date cannot be in the future.'),
      );
      expect(v, isA<ValidationFailure>());
      expect(v.message, 'Transaction date cannot be in the future.');
    });

    test('business rules keep their code and safe message', () {
      final f = mapError(
        rpc(
          'GROUP_MEMBER_LIMIT',
          'A group can have at most 10 active members.',
        ),
      );
      expect(f, isA<RuleFailure>());
      expect((f as RuleFailure).code, 'GROUP_MEMBER_LIMIT');
    });

    test('raw database errors never leak their text', () {
      final f = mapError(
        const PostgrestException(
          message: 'duplicate key value violates unique constraint "x"',
          code: '23505',
        ),
      );
      expect(f, isA<UnexpectedFailure>());
      expect(f.message, isNot(contains('constraint')));
      expect(
        mapError(
          const PostgrestException(
            message: 'permission denied for table transactions',
            code: '42501',
          ),
        ),
        isA<PermissionFailure>(),
      );
    });
  });

  test('edge function error body', () {
    final f = mapError(
      const FunctionException(
        status: 409,
        details: {
          'error': {
            'code': 'USERNAME_TAKEN',
            'message': 'This username is already taken.',
          },
        },
      ),
    );
    expect(f, isA<RuleFailure>());
    expect(f.message, 'This username is already taken.');
  });

  test('socket errors are network failures', () {
    expect(mapError(const SocketException('no route')), isA<NetworkFailure>());
  });

  test('unknown errors become a generic message', () {
    expect(
      mapError(StateError('boom')).message,
      'Something went wrong. Please try again.',
    );
  });
}
