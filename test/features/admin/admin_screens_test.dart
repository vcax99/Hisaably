import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hisaably/app.dart';
import 'package:hisaably/features/auth/data/auth_repository.dart';
import 'package:hisaably/features/groups/data/groups_repository.dart';
import 'package:hisaably/features/groups/domain/group.dart';
import 'package:hisaably/features/groups/presentation/group_detail_screen.dart';
import 'package:hisaably/features/auth/domain/user_context.dart';
import 'package:hisaably/features/users/data/users_repository.dart';
import 'package:hisaably/routing/app_router.dart';
import 'package:hisaably/routing/routes.dart';

import '../../helpers/fake_admin_repositories.dart';
import '../../helpers/fake_auth_repository.dart';

Future<(GoRouter, FakeAdminBackend)> _pumpAsAdmin(
  WidgetTester tester, {
  required String location,
  FakeAdminBackend? backend,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  final db = backend ?? FakeAdminBackend();
  if (!db.users.containsKey(superAdminContext.profile.id)) {
    db.addUser(
      'Bikash',
      'vcax99',
      superAdmin: true,
      id: superAdminContext.profile.id,
    );
  }
  final auth = FakeAuthRepository(
    accounts: {'vcax99': FakeAccount('pw', superAdminContext)},
    signedInAs: 'vcax99',
  );
  final container = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(auth),
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

Future<void> _enter(WidgetTester tester, String label, String text) =>
    tester.enterText(find.widgetWithText(TextFormField, label), text);

void main() {
  group('Users', () {
    testWidgets('list shows users and search filters them', (tester) async {
      final db = FakeAdminBackend()
        ..addUser('Asha Rao', 'asha')
        ..addUser('Rahul K', 'rahul');
      await _pumpAsAdmin(tester, location: Routes.adminUsers, backend: db);

      expect(find.text('Asha Rao'), findsOneWidget);
      expect(find.text('Rahul K'), findsOneWidget);
      expect(find.text('Super Admin'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'rah');
      await tester.pumpAndSettle();
      expect(find.text('Asha Rao'), findsNothing);
      expect(find.text('Rahul K'), findsOneWidget);
    });

    testWidgets('create user validates, then creates and shows credentials', (
      tester,
    ) async {
      final db = FakeAdminBackend()..addUser('Asha', 'asha');
      final (router, _) = await _pumpAsAdmin(
        tester,
        location: Routes.adminNewUser,
        backend: db,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Create user'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a name'), findsOneWidget);
      expect(find.text('At least 8 characters'), findsOneWidget);

      await _enter(tester, 'Full name', 'Asha Two');
      await _enter(tester, 'Username', 'asha');
      await _enter(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Create user'));
      await tester.pumpAndSettle();
      expect(find.text('This username is already taken.'), findsOneWidget);

      await _enter(tester, 'Username', 'Asha.Two');
      await tester.tap(find.widgetWithText(FilledButton, 'Create user'));
      await tester.pumpAndSettle();
      expect(find.text('User created'), findsOneWidget);
      expect(find.textContaining('Username: asha.two'), findsOneWidget);
      expect(db.calls, contains('createUser:asha.two'));

      await tester.tap(find.widgetWithText(TextButton, 'Done'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, Routes.adminUsers);
      expect(find.text('Asha Two'), findsOneWidget);
    });

    testWidgets('generate password fills and reveals the field', (
      tester,
    ) async {
      await _pumpAsAdmin(tester, location: Routes.adminNewUser);
      await tester.tap(find.text('Generate password'));
      await tester.pump();
      final field = tester.widget<EditableText>(
        find.descendant(
          of: find.widgetWithText(TextFormField, 'Password'),
          matching: find.byType(EditableText),
        ),
      );
      expect(field.controller.text.length, 10);
      expect(field.obscureText, isFalse);
    });

    testWidgets('own account: no disable/delete', (tester) async {
      await _pumpAsAdmin(
        tester,
        location: Routes.adminUser(superAdminContext.profile.id),
      );
      expect(find.text('Reset password'), findsOneWidget);
      expect(find.text('Disable user'), findsNothing);
      expect(find.text('Delete user'), findsNothing);
      expect(find.text('You'), findsOneWidget);
    });

    testWidgets('disable another user after confirmation', (tester) async {
      final db = FakeAdminBackend();
      final asha = db.addUser('Asha', 'asha');
      await _pumpAsAdmin(
        tester,
        location: Routes.adminUser(asha.id),
        backend: db,
      );

      await tester.tap(find.text('Disable user'));
      await tester.pumpAndSettle();
      expect(find.text('Disable Asha?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Disable'));
      await tester.pumpAndSettle();

      expect(db.calls, contains('setDisabled:${asha.id}:true'));
      expect(find.text('Enable user'), findsOneWidget);
      expect(find.text('Disabled'), findsOneWidget);
    });

    testWidgets('delete user goes back to the list', (tester) async {
      final db = FakeAdminBackend();
      final asha = db.addUser('Asha', 'asha');
      final (router, _) = await _pumpAsAdmin(
        tester,
        location: Routes.adminUsers,
        backend: db,
      );
      unawaited(router.push(Routes.adminUser(asha.id)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Delete user'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(db.calls, contains('deleteUser:${asha.id}'));
      expect(router.state.uri.path, Routes.adminUsers);
      expect(find.text('Asha'), findsNothing);
    });
  });

  group('Groups', () {
    testWidgets('list shows active counts and a Full chip', (tester) async {
      final db = FakeAdminBackend();
      final roomies = db.addGroup('Roomies');
      db.addGroup('Trip');
      for (var i = 0; i < 10; i++) {
        db.join(roomies.id, db.addUser('User $i', 'user$i').id);
      }
      await _pumpAsAdmin(tester, location: Routes.adminGroups, backend: db);

      expect(find.text('10/10 active members'), findsOneWidget);
      expect(find.text('0/10 active members'), findsOneWidget);
      expect(find.text('Full'), findsOneWidget);
    });

    testWidgets('add member via the picker', (tester) async {
      final db = FakeAdminBackend();
      final g = db.addGroup('Roomies');
      final asha = db.addUser('Asha', 'asha');
      db.addUser('Off', 'off').let((u) => db.users[u.id] = u); // stays active
      await _pumpAsAdmin(
        tester,
        location: Routes.adminGroup(g.id),
        backend: db,
      );

      expect(find.text('No members yet'), findsOneWidget);
      await tester.tap(find.text('Add member'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Asha'));
      await tester.pumpAndSettle();

      expect(db.calls, contains('addMember:${g.id}:${asha.id}'));
      expect(find.text('1 of 10 active members'), findsOneWidget);
      expect(find.text('@asha'), findsOneWidget);
    });

    testWidgets('Add member is disabled when the group is full', (
      tester,
    ) async {
      final db = FakeAdminBackend();
      final g = db.addGroup('Roomies');
      for (var i = 0; i < 10; i++) {
        db.join(g.id, db.addUser('User $i', 'user$i').id);
      }
      await _pumpAsAdmin(
        tester,
        location: Routes.adminGroup(g.id),
        backend: db,
      );

      final button = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Add member'),
          matching: find.byType(TextButton),
        ),
      );
      expect(button.onPressed, isNull);
      expect(
        find.textContaining('10 active members, the maximum'),
        findsOneWidget,
      );
    });

    testWidgets('member menu: make Group Admin, then remove', (tester) async {
      final db = FakeAdminBackend();
      final g = db.addGroup('Roomies');
      final asha = db.addUser('Asha', 'asha');
      db.join(g.id, asha.id);
      await _pumpAsAdmin(
        tester,
        location: Routes.adminGroup(g.id),
        backend: db,
      );

      await tester.tap(find.byTooltip('Member actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Make Group Admin'));
      await tester.pumpAndSettle();
      expect(db.calls, contains('setMemberAdmin:${asha.id}:true'));
      expect(find.text('Group Admin'), findsOneWidget);

      await tester.tap(find.byTooltip('Member actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from group'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(db.calls, contains('removeMember:${g.id}:${asha.id}'));
      expect(find.text('No members yet'), findsOneWidget);
    });
  });

  group('GroupPermissions', () {
    GroupMember member(String id, {bool admin = false}) => GroupMember(
      userId: id,
      name: id,
      username: id,
      groupRole: admin ? GroupRole.groupAdmin : GroupRole.member,
      status: RecordStatus.active,
      profileActive: true,
    );

    test('super admin can do everything', () {
      const p = GroupPermissions(isSuperAdmin: true, isGroupAdmin: false);
      expect(p.canAddOrRemove && p.canChangeRoles && p.canRename, isTrue);
      expect(p.canToggleMember(member('x', admin: true), 'me'), isTrue);
    });

    test('group admin: rename + toggle plain members only (not self)', () {
      const p = GroupPermissions(isSuperAdmin: false, isGroupAdmin: true);
      expect(p.canRename, isTrue);
      expect(p.canAddOrRemove, isFalse);
      expect(p.canChangeRoles, isFalse);
      expect(p.canChangeGroupStatus, isFalse);
      expect(p.canToggleMember(member('x'), 'me'), isTrue);
      expect(p.canToggleMember(member('me'), 'me'), isFalse);
      expect(p.canToggleMember(member('y', admin: true), 'me'), isFalse);
    });

    test('member can only view', () {
      const p = GroupPermissions(isSuperAdmin: false, isGroupAdmin: false);
      expect(p.canRename || p.canAddOrRemove || p.canChangeRoles, isFalse);
      expect(p.canToggleMember(member('x'), 'me'), isFalse);
    });
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
