import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/errors/app_failure.dart';
import 'package:hisaably/features/auth/application/session_controller.dart';
import 'package:hisaably/routing/routes.dart';
import 'package:hisaably/routing/session_redirect.dart';

import '../helpers/fake_auth_repository.dart';

void main() {
  const loading = AsyncLoading<SessionState>();
  const signedOut = AsyncData<SessionState>(SessionSignedOut());
  final member = AsyncData<SessionState>(SessionSignedIn(memberContext));
  final admin = AsyncData<SessionState>(SessionSignedIn(superAdminContext));

  test('unknown session goes to splash', () {
    expect(sessionRedirect(loading, Routes.login), Routes.splash);
    expect(sessionRedirect(loading, Routes.splash), isNull);
    expect(
      sessionRedirect(
        const AsyncError<SessionState>(NetworkFailure(), StackTrace.empty),
        Routes.memberDashboard,
      ),
      Routes.splash,
    );
  });

  test('signed out always lands on login', () {
    expect(sessionRedirect(signedOut, Routes.splash), Routes.login);
    expect(sessionRedirect(signedOut, Routes.adminUsers), Routes.login);
    expect(sessionRedirect(signedOut, Routes.settings), Routes.login);
    expect(sessionRedirect(signedOut, Routes.login), isNull);
  });

  test('member goes to member home and cannot open admin screens', () {
    expect(sessionRedirect(member, Routes.login), Routes.memberDashboard);
    expect(sessionRedirect(member, Routes.adminUsers), Routes.memberDashboard);
    expect(sessionRedirect(member, Routes.memberExpenses), isNull);
    expect(sessionRedirect(member, Routes.settings), isNull);
  });

  test('super admin goes to admin home and not member shell', () {
    expect(sessionRedirect(admin, Routes.splash), Routes.adminDashboard);
    expect(
      sessionRedirect(admin, Routes.memberDashboard),
      Routes.adminDashboard,
    );
    expect(sessionRedirect(admin, Routes.adminUsers), isNull);
    expect(sessionRedirect(admin, Routes.addTransaction('expense')), isNull);
  });

  test(
    'refreshing keeps the current screen (previous value is used)',
    () async {
      // Produce a real "loading with previous value" state via a provider.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final provider = FutureProvider<SessionState>((ref) async {
        return SessionSignedIn(memberContext);
      });
      container.listen(provider, (_, _) {});
      await container.read(provider.future);
      container.invalidate(provider);
      final refreshing = container.read(provider);
      expect(refreshing.isLoading, isTrue);
      expect(sessionRedirect(refreshing, Routes.memberIncome), isNull);
    },
  );
}
