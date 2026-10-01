import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hisaably/app.dart';
import 'package:hisaably/features/auth/data/auth_repository.dart';
import 'package:hisaably/features/auth/domain/user_context.dart';
import 'package:hisaably/features/groups/data/groups_repository.dart';
import 'package:hisaably/features/users/data/users_repository.dart';
import 'package:hisaably/routing/app_router.dart';
import 'package:hisaably/routing/routes.dart';

import '../../helpers/fake_admin_repositories.dart';
import '../../helpers/fake_auth_repository.dart';

UserContext _ctx({required bool groupAdmin, bool inGroup = true}) =>
    buildContext(
      id: 'me',
      name: 'Asha',
      username: 'asha',
      memberships: [
        if (inGroup)
          GroupMembership(
            groupId: 'g1',
            groupName: 'Roomies',
            groupStatus: RecordStatus.active,
            groupRole: groupAdmin ? GroupRole.groupAdmin : GroupRole.member,
            membershipStatus: RecordStatus.active,
          ),
      ],
    );

/// Backend: group g1 "Roomies" with me (admin or member), Ravi (member) and
/// Meera (another Group Admin).
FakeAdminBackend _backend({required bool groupAdmin}) {
  final db = FakeAdminBackend()..addGroup('Roomies', id: 'g1');
  db
    ..addUser('Asha', 'asha', id: 'me')
    ..addUser('Ravi', 'ravi', id: 'ravi')
    ..addUser('Meera', 'meera', id: 'meera');
  db
    ..join('g1', 'me', admin: groupAdmin)
    ..join('g1', 'ravi')
    ..join('g1', 'meera', admin: true);
  return db;
}

Future<(GoRouter, FakeAdminBackend)> _pump(
  WidgetTester tester, {
  required UserContext context,
  required FakeAdminBackend db,
  String location = Routes.memberGroups,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(
          accounts: {'asha': FakeAccount('pw', context)},
          signedInAs: 'asha',
        ),
      ),
      usersRepositoryProvider.overrideWithValue(FakeUsersRepository(db)),
      groupsRepositoryProvider.overrideWithValue(FakeGroupsRepository(db)),
    ],
    retry: (_, _) => null,
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const HisaablyApp()),
  );
  await tester.pumpAndSettle();
  final router = container.read(appRouterProvider)..go(location);
  await tester.pumpAndSettle();
  return (router, db);
}

void main() {
  testWidgets('member: sees own group, view-only detail', (tester) async {
    final (router, _) = await _pump(
      tester,
      context: _ctx(groupAdmin: false),
      db: _backend(groupAdmin: false),
    );
    expect(find.text('Roomies'), findsOneWidget);
    expect(find.text('3/10 active members'), findsOneWidget);
    expect(find.text('Group Admin'), findsNothing);

    await tester.tap(find.text('Roomies'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, Routes.memberGroup('g1'));
    expect(find.text('@ravi'), findsOneWidget);
    expect(find.text('Asha (you)'), findsOneWidget);
    expect(find.text('Rename group'), findsNothing);
    expect(find.text('Disable group'), findsNothing);
    expect(find.text('Add member'), findsNothing);
    expect(find.byTooltip('Member actions'), findsNothing);
  });

  testWidgets('group admin: rename + disable plain members only', (
    tester,
  ) async {
    final (_, db) = await _pump(
      tester,
      context: _ctx(groupAdmin: true),
      db: _backend(groupAdmin: true),
    );
    expect(find.text('Group Admin'), findsOneWidget); // badge on the card

    await tester.tap(find.text('Roomies'));
    await tester.pumpAndSettle();
    expect(find.text('Rename group'), findsOneWidget);
    expect(find.text('Disable group'), findsNothing);
    expect(find.text('Add member'), findsNothing);
    // Only Ravi (plain member) has a menu: not me, not Meera (Group Admin).
    expect(find.byTooltip('Member actions'), findsOneWidget);

    await tester.tap(find.byTooltip('Member actions'));
    await tester.pumpAndSettle();
    expect(find.text('Disable in group'), findsOneWidget);
    expect(find.text('Make Group Admin'), findsNothing);
    expect(find.text('Remove from group'), findsNothing);

    await tester.tap(find.text('Disable in group'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Disable'));
    await tester.pumpAndSettle();
    expect(db.calls, contains('setMemberActive:ravi:false'));
    expect(find.text('2 of 10 active members'), findsOneWidget);
  });

  testWidgets('group admin can rename the group', (tester) async {
    await _pump(
      tester,
      context: _ctx(groupAdmin: true),
      db: _backend(groupAdmin: true),
      location: Routes.memberGroup('g1'),
    );
    await tester.tap(find.text('Rename group'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Flat 4B');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Flat 4B'), findsWidgets);
  });

  testWidgets('no groups: friendly empty state', (tester) async {
    await _pump(
      tester,
      context: _ctx(groupAdmin: false, inGroup: false),
      db: FakeAdminBackend(),
    );
    expect(find.text('You are not in any group yet'), findsOneWidget);
    expect(find.textContaining('Ask your administrator'), findsOneWidget);
  });
}
