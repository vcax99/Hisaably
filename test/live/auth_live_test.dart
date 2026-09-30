// Live test: SupabaseAuthRepository against the real dev backend.
// Skipped unless keys are in the environment. Run with:
//   scripts/run_live_tests.sh
@Tags(['live'])
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/errors/app_failure.dart';
import 'package:hisaably/core/errors/error_mapper.dart';
import 'package:hisaably/features/auth/data/auth_repository.dart';
import 'package:hisaably/features/auth/domain/user_context.dart';
import 'package:hisaably/features/auth/domain/username.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _env = Platform.environment;
final _url = _env['SUPABASE_URL'];
final _publishable = _env['SUPABASE_PUBLISHABLE_KEY'];
final _service = _env['SUPABASE_SERVICE_ROLE_KEY'];
final _skip = (_url == null || _publishable == null || _service == null)
    ? 'Live keys not set (run scripts/run_live_tests.sh)'
    : null;

String _random(int n) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final r = Random.secure();
  return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
}

void main() {
  late SupabaseClient admin;
  final createdIds = <String>[];
  final run = _random(6);

  Future<String> createUser(String username, String password) async {
    final res = await admin.auth.admin.createUser(
      AdminUserAttributes(
        email: Username.toAuthEmail(username),
        password: password,
        emailConfirm: true,
        userMetadata: {'username': username, 'name': 'Live $username'},
      ),
    );
    createdIds.add(res.user!.id);
    return res.user!.id;
  }

  Future<SupabaseAuthRepository> newRepo() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final client = SupabaseClient(
      _url!,
      _publishable!,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    return SupabaseAuthRepository(client, UserContextCache(prefs));
  }

  setUpAll(() {
    if (_skip != null) return;
    admin = SupabaseClient(
      _url!,
      _service!,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
  });

  tearDownAll(() async {
    if (_skip != null) return;
    for (final id in createdIds) {
      await admin.auth.admin.deleteUser(id);
    }
  });

  test(
    'username login, context, cache, permission mapping, sign out',
    () async {
      final username = 'live_u_$run';
      final password = _random(16);
      final id = await createUser(username, password);
      final repo = await newRepo();

      await repo.signIn(username: username.toUpperCase(), password: password);
      expect(repo.currentUserId, id);

      final context = await repo.fetchContext();
      expect(context.profile.username, username);
      expect(context.profile.role, AppRole.user);
      expect(context.profile.isActive, isTrue);
      expect(context.memberships, isEmpty);
      expect(repo.cachedContext(id)?.profile.id, id);

      // A real RPC permission error maps to a user-safe PermissionFailure.
      final client = SupabaseClient(_url!, _publishable!);
      try {
        await client.auth.signInWithPassword(
          email: Username.toAuthEmail(username),
          password: password,
        );
        await client.rpc<dynamic>('get_admin_overview');
        fail('member called admin RPC');
      } catch (e) {
        expect(mapError(e), isA<PermissionFailure>());
      }

      await repo.signOut();
      expect(repo.currentUserId, isNull);
      expect(repo.cachedContext(id), isNull);
    },
    skip: _skip,
  );

  test('wrong password -> AuthFailure; unknown user -> AuthFailure', () async {
    final username = 'live_w_$run';
    await createUser(username, _random(16));
    final repo = await newRepo();
    await expectLater(
      repo.signIn(username: username, password: 'wrong-password'),
      throwsA(isA<AuthFailure>()),
    );
    await expectLater(
      repo.signIn(username: 'nobody_$run', password: 'whatever1'),
      throwsA(isA<AuthFailure>()),
    );
  }, skip: _skip);

  test('banned (disabled) user -> AccountDisabledFailure at login', () async {
    final username = 'live_b_$run';
    final password = _random(16);
    final id = await createUser(username, password);
    await admin.auth.admin.updateUserById(
      id,
      attributes: AdminUserAttributes(banDuration: '876000h'),
    );
    final repo = await newRepo();
    await expectLater(
      repo.signIn(username: username, password: password),
      throwsA(isA<AccountDisabledFailure>()),
    );
  }, skip: _skip);

  test('profile DISABLED (old session) -> context reports disabled', () async {
    final username = 'live_d_$run';
    final password = _random(16);
    final id = await createUser(username, password);
    final repo = await newRepo();
    await repo.signIn(username: username, password: password);
    await admin.from('profiles').update({'status': 'DISABLED'}).eq('id', id);

    final context = await repo.fetchContext();
    expect(context.profile.isActive, isFalse);
  }, skip: _skip);
}
