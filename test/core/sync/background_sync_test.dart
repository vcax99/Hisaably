import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/sync/background_sync.dart';

void main() {
  final now = DateTime.utc(2026, 10, 1, 12);
  String sessionJson({int? expiresAt, String userId = 'u1'}) => jsonEncode({
    'access_token': 'tok',
    'refresh_token': 'never-used-in-background',
    'expires_at':
        expiresAt ??
        now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
    'user': {'id': userId},
  });

  test('session key matches supabase_flutter', () {
    expect(
      persistedSessionKey('https://ckajubnieifpaxoznmtt.supabase.co'),
      'sb-ckajubnieifpaxoznmtt-auth-token',
    );
  });

  test('parses the persisted session; rejects junk', () {
    final s = PersistedSession.parse(sessionJson())!;
    expect(s.userId, 'u1');
    expect(s.accessToken, 'tok');
    expect(s.isValidAt(now), isTrue);
    expect(PersistedSession.parse(null), isNull);
    expect(PersistedSession.parse('not json'), isNull);
    expect(PersistedSession.parse('{"access_token":"x"}'), isNull);
  });

  test('preconditions', () {
    final valid = PersistedSession.parse(sessionJson());
    final expiring = PersistedSession.parse(
      sessionJson(expiresAt: now.millisecondsSinceEpoch ~/ 1000 + 30),
    );
    BackgroundSkip? check({
      bool configured = true,
      PersistedSession? session,
      String? owner = 'u1',
    }) => backgroundPreconditions(
      configured: configured,
      session: session,
      localOwner: owner,
      now: now,
    );

    expect(check(session: valid), isNull, reason: 'ok to sync');
    expect(
      check(configured: false, session: valid),
      BackgroundSkip.notConfigured,
    );
    expect(check(), BackgroundSkip.noSession);
    expect(
      check(session: expiring),
      BackgroundSkip.tokenExpired,
      reason: 'never refreshes in the background',
    );
    expect(
      check(session: valid, owner: 'someone-else'),
      BackgroundSkip.otherUser,
    );
    expect(check(session: valid, owner: null), BackgroundSkip.otherUser);
  });
}
