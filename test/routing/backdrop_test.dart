import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/app.dart';
import 'package:hisaably/core/widgets/wave_background.dart';
import 'package:hisaably/features/auth/data/auth_repository.dart';
import 'package:hisaably/features/groups/data/groups_repository.dart';
import 'package:hisaably/routing/app_router.dart';
import 'package:hisaably/routing/routes.dart';

import '../helpers/fake_admin_repositories.dart';
import '../helpers/fake_auth_repository.dart';

/// Every page must sit on its own opaque backdrop (scaffolds are
/// transparent): a missing one shows up as a white/see-through screen.
void main() {
  Future<ProviderContainer> pump(WidgetTester tester, {String? as}) async {
    final container = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(
          FakeAuthRepository(
            accounts: {'admin': FakeAccount('pw', superAdminContext)},
            signedInAs: as,
          ),
        ),
        groupsRepositoryProvider.overrideWithValue(
          FakeGroupsRepository(FakeAdminBackend()),
        ),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const HisaablyApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('sign-in screen has the backdrop', (tester) async {
    await pump(tester);
    expect(find.text('Sign in'), findsWidgets);
    expect(find.byType(WaveBackdrop), findsOneWidget);
  });

  testWidgets('tab pages and pushed pages have their own backdrop', (
    tester,
  ) async {
    final container = await pump(tester, as: 'admin');
    expect(find.byType(WaveBackdrop), findsOneWidget, reason: 'dashboard tab');
    unawaited(container.read(appRouterProvider).push(Routes.notifications));
    await tester.pumpAndSettle();
    expect(
      find.byType(WaveBackdrop),
      findsOneWidget,
      reason: 'notifications page (the tab below is offstage)',
    );
  });
}
