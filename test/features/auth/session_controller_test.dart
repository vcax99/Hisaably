import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/errors/app_failure.dart';
import 'package:hisaably/features/auth/application/session_controller.dart';
import 'package:hisaably/features/auth/data/auth_repository.dart';
import 'package:hisaably/features/auth/domain/user_context.dart';

import '../../helpers/fake_auth_repository.dart';

ProviderContainer _container(FakeAuthRepository repo) {
  final container = ProviderContainer(
    overrides: [authRepositoryProvider.overrideWithValue(repo)],
    retry: (_, _) => null,
  );
  addTearDown(container.dispose);
  // Keep the provider alive for the duration of the test.
  container.listen(sessionControllerProvider, (_, _) {});
  return container;
}

Future<SessionState> _settled(ProviderContainer c) async {
  for (var i = 0; i < 20; i++) {
    final value = c.read(sessionControllerProvider);
    if (!value.isLoading) return value.requireValue;
    await Future<void>.delayed(Duration.zero);
  }
  return c.read(sessionControllerProvider).requireValue;
}

void main() {
  test('no session -> signed out', () async {
    final c = _container(FakeAuthRepository());
    expect(await _settled(c), isA<SessionSignedOut>());
  });

  test('existing session loads profile, role and memberships', () async {
    final repo = FakeAuthRepository(
      accounts: {'vcax99': FakeAccount('pw', superAdminContext)},
      signedInAs: 'vcax99',
    );
    final c = _container(repo);
    final state = await _settled(c);
    expect(state, isA<SessionSignedIn>());
    expect((state as SessionSignedIn).context.profile.isSuperAdmin, isTrue);
    expect(state.offline, isFalse);
  });

  test('sign in with username then sign out', () async {
    final repo = FakeAuthRepository(
      accounts: {'asha': FakeAccount('secret123', memberContext)},
    );
    final c = _container(repo);
    expect(await _settled(c), isA<SessionSignedOut>());

    await c
        .read(sessionControllerProvider.notifier)
        .signIn(username: ' Asha ', password: 'secret123');
    await Future<void>.delayed(Duration.zero);
    final state = await _settled(c);
    expect(state, isA<SessionSignedIn>());

    await c.read(sessionControllerProvider.notifier).signOut();
    await Future<void>.delayed(Duration.zero);
    expect(await _settled(c), isA<SessionSignedOut>());
  });

  test('wrong password throws AuthFailure and stays signed out', () async {
    final repo = FakeAuthRepository(
      accounts: {'asha': FakeAccount('secret123', memberContext)},
    );
    final c = _container(repo);
    await _settled(c);
    await expectLater(
      c
          .read(sessionControllerProvider.notifier)
          .signIn(username: 'asha', password: 'nope'),
      throwsA(isA<AuthFailure>()),
    );
    expect(await _settled(c), isA<SessionSignedOut>());
  });

  test(
    'disabled profile with an old session is signed out with a notice',
    () async {
      final disabled = buildContext(status: RecordStatus.disabled);
      final repo = FakeAuthRepository(
        accounts: {'asha': FakeAccount('pw', disabled)},
        signedInAs: 'asha',
      );
      final c = _container(repo);
      await _settled(c);
      await Future<void>.delayed(Duration.zero);
      expect(await _settled(c), isA<SessionSignedOut>());
      expect(repo.signOutCalls, 1);
      expect(c.read(authNoticeProvider), contains('disabled'));
    },
  );

  test('server says ACCOUNT_DISABLED -> signed out with notice', () async {
    final repo = FakeAuthRepository(
      accounts: {'asha': FakeAccount('pw', memberContext)},
      signedInAs: 'asha',
    )..fetchError = const AccountDisabledFailure();
    final c = _container(repo);
    await _settled(c);
    await Future<void>.delayed(Duration.zero);
    expect(await _settled(c), isA<SessionSignedOut>());
    expect(c.read(authNoticeProvider), isNotNull);
  });

  test('offline start-up uses the cached context of the same user', () async {
    final repo =
        FakeAuthRepository(
            accounts: {'asha': FakeAccount('pw', memberContext)},
            signedInAs: 'asha',
          )
          ..cache = memberContext
          ..fetchError = const NetworkFailure();
    final c = _container(repo);
    final state = await _settled(c);
    expect(state, isA<SessionSignedIn>());
    expect((state as SessionSignedIn).offline, isTrue);
  });

  test('offline start-up without cache surfaces a NetworkFailure', () async {
    final repo = FakeAuthRepository(
      accounts: {'asha': FakeAccount('pw', memberContext)},
      signedInAs: 'asha',
    )..fetchError = const NetworkFailure();
    final c = _container(repo);
    for (
      var i = 0;
      i < 20 && c.read(sessionControllerProvider).isLoading;
      i++
    ) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(c.read(sessionControllerProvider).error, isA<NetworkFailure>());
  });

  test('a cached context is never used for a disabled profile', () async {
    final disabled = buildContext(status: RecordStatus.disabled);
    final repo =
        FakeAuthRepository(
            accounts: {'asha': FakeAccount('pw', memberContext)},
            signedInAs: 'asha',
          )
          ..cache = disabled
          ..fetchError = const NetworkFailure();
    final c = _container(repo);
    for (
      var i = 0;
      i < 20 && c.read(sessionControllerProvider).isLoading;
      i++
    ) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(c.read(sessionControllerProvider).hasError, isTrue);
  });

  test('refresh re-fetches the context (forced)', () async {
    final repo = FakeAuthRepository(
      accounts: {'asha': FakeAccount('pw', memberContext)},
      signedInAs: 'asha',
    );
    final c = _container(repo);
    await _settled(c);
    expect(repo.fetchCalls, 1);
    c.read(sessionControllerProvider.notifier).refresh();
    await _settled(c);
    expect(repo.fetchCalls, 1, reason: 'throttled within 30 s');
    c.read(sessionControllerProvider.notifier).refresh(force: true);
    await Future<void>.delayed(Duration.zero);
    await _settled(c);
    expect(repo.fetchCalls, 2);
  });
}
