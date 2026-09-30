import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hisaably/app.dart';
import 'package:hisaably/features/auth/data/auth_repository.dart';
import 'package:hisaably/features/auth/domain/user_context.dart';
import 'package:hisaably/routing/app_router.dart';
import 'package:hisaably/routing/routes.dart';

import '../helpers/fake_auth_repository.dart';

Future<(GoRouter, FakeAuthRepository)> _pumpApp(
  WidgetTester tester, {
  String? signedInAs,
}) async {
  final repo = FakeAuthRepository(
    accounts: {
      'asha': FakeAccount('secret123', memberContext),
      'vcax99': FakeAccount('admin-pass', superAdminContext),
      'banned': FakeAccount(
        'pw',
        buildContext(id: 'b', username: 'banned'),
        banned: true,
      ),
      'off': FakeAccount(
        'pw',
        buildContext(id: 'off', username: 'off', status: RecordStatus.disabled),
      ),
    },
    signedInAs: signedInAs,
  );
  final container = ProviderContainer(
    overrides: [authRepositoryProvider.overrideWithValue(repo)],
    retry: (_, _) => null,
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const HisaablyApp()),
  );
  await tester.pumpAndSettle();
  return (container.read(appRouterProvider), repo);
}

Future<void> _login(
  WidgetTester tester,
  String username,
  String password,
) async {
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Username'),
    username,
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Password'),
    password,
  );
  await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
  await tester.pumpAndSettle();
}

Finder _nav(String label) => find.byKey(ValueKey('nav-$label'));

void main() {
  testWidgets('signed out: login screen, validation', (tester) async {
    await _pumpApp(tester);
    expect(find.text('Hisaably'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    expect(find.text('Enter your username'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);
    expect(
      find.text('Member shell'),
      findsNothing,
      reason: 'debug preview removed',
    );
  });

  testWidgets('wrong password shows a friendly error', (tester) async {
    await _pumpApp(tester);
    await _login(tester, 'asha', 'wrong');
    expect(find.text('Incorrect username or password.'), findsOneWidget);
  });

  testWidgets('banned account shows disabled message', (tester) async {
    await _pumpApp(tester);
    await _login(tester, 'banned', 'pw');
    expect(find.textContaining('disabled'), findsOneWidget);
  });

  testWidgets('disabled profile is signed out right after login', (
    tester,
  ) async {
    final (router, repo) = await _pumpApp(tester);
    await _login(tester, 'off', 'pw');
    expect(router.state.uri.path, Routes.login);
    expect(repo.signOutCalls, 1);
    expect(find.textContaining('disabled'), findsOneWidget);
  });

  testWidgets('member login -> member shell; + opens both choices', (
    tester,
  ) async {
    final (router, _) = await _pumpApp(tester);
    await _login(tester, 'Asha', 'secret123');
    expect(router.state.uri.path, Routes.memberDashboard);
    for (final label in ['Dashboard', 'Expenses', 'Income', 'Groups']) {
      expect(_nav(label), findsOneWidget);
    }

    await tester.tap(_nav('Expenses'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, Routes.memberExpenses);

    await tester.tap(find.bySemanticsLabel('Add transaction'));
    await tester.pumpAndSettle();
    expect(find.text('Add Expense'), findsOneWidget);
    await tester.tap(find.text('Add Income'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, Routes.addTransaction('income'));
  });

  testWidgets('member cannot open admin routes', (tester) async {
    final (router, _) = await _pumpApp(tester, signedInAs: 'asha');
    router.go(Routes.adminUsers);
    await tester.pumpAndSettle();
    expect(router.state.uri.path, Routes.memberDashboard);
  });

  testWidgets('existing admin session opens admin shell; sign out works', (
    tester,
  ) async {
    final (router, _) = await _pumpApp(tester, signedInAs: 'vcax99');
    expect(router.state.uri.path, Routes.adminDashboard);
    for (final label in ['Dashboard', 'Groups', 'Users', 'More']) {
      expect(_nav(label), findsOneWidget);
    }
    expect(_nav('Expenses'), findsNothing);

    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    expect(find.text('@vcax99'), findsOneWidget);
    expect(find.text('Super Admin'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Sign out'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, Routes.login);
  });
}
