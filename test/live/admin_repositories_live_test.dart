// Live test: UsersRepository + GroupsRepository against the dev backend,
// signed in as a throwaway Super Admin. Run with scripts/run_live_tests.sh.
@Tags(['live'])
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/errors/app_failure.dart';
import 'package:hisaably/features/auth/domain/username.dart';
import 'package:hisaably/features/groups/data/groups_repository.dart';
import 'package:hisaably/features/users/data/users_repository.dart';
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
  late SupabaseClient admin; // service role: setup/cleanup only
  late SupabaseClient saClient; // signed in as the throwaway Super Admin
  late UsersRepository users;
  late GroupsRepository groups;
  final run = _random(6);
  final cleanupUserIds = <String>[];
  final cleanupGroupIds = <String>[];

  setUpAll(() async {
    if (_skip != null) return;
    admin = SupabaseClient(
      _url!,
      _service!,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    final saName = 'live_sa_$run';
    final saPass = _random(16);
    final res = await admin.auth.admin.createUser(
      AdminUserAttributes(
        email: Username.toAuthEmail(saName),
        password: saPass,
        emailConfirm: true,
        userMetadata: {'username': saName, 'name': 'Live SA'},
      ),
    );
    cleanupUserIds.add(res.user!.id);
    await admin
        .from('profiles')
        .update({'role': 'SUPER_ADMIN'})
        .eq('id', res.user!.id);

    saClient = SupabaseClient(
      _url!,
      _publishable!,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    await saClient.auth.signInWithPassword(
      email: Username.toAuthEmail(saName),
      password: saPass,
    );
    users = SupabaseUsersRepository(saClient);
    groups = SupabaseGroupsRepository(saClient);
  });

  tearDownAll(() async {
    if (_skip != null) return;
    for (final g in cleanupGroupIds) {
      await admin.from('group_members').delete().eq('group_id', g);
      await admin.from('group_categories').delete().eq('group_id', g);
      await admin.from('groups').delete().eq('id', g);
    }
    for (final id in cleanupUserIds) {
      try {
        await admin.auth.admin.deleteUser(id);
      } catch (_) {}
    }
  });

  test('users: create, list, rename, reset, disable/enable, delete', () async {
    final username = 'live_user_$run';
    final created = await users.createUser(
      name: 'Live User',
      username: username.toUpperCase(),
      password: _random(12),
    );
    cleanupUserIds.add(created.id);
    expect(created.username, username);
    expect(created.isActive, isTrue);

    await expectLater(
      users.createUser(name: 'Dup', username: username, password: _random(12)),
      throwsA(
        isA<RuleFailure>().having((f) => f.code, 'code', 'USERNAME_TAKEN'),
      ),
    );
    await expectLater(
      users.createUser(name: 'Short', username: 'live_s_$run', password: 'x'),
      throwsA(isA<ValidationFailure>()),
    );

    final list = await users.listUsers();
    expect(list.any((u) => u.id == created.id), isTrue);
    final names = [for (final u in list) u.name.toLowerCase()];
    expect(names, [...names]..sort(), reason: 'users sorted A→Z');

    await users.rename(created.id, '  Live   Renamed ');
    expect((await users.getUser(created.id)).name, 'Live Renamed');

    await users.resetPassword(created.id, _random(12));

    await users.setDisabled(created.id, disabled: true);
    expect((await users.getUser(created.id)).isActive, isFalse);
    await users.setDisabled(created.id, disabled: false);
    expect((await users.getUser(created.id)).isActive, isTrue);

    await users.deleteUser(created.id);
    cleanupUserIds.remove(created.id);
    await expectLater(users.getUser(created.id), throwsA(isA<AppFailure>()));
  }, skip: _skip);

  test('groups: create, rename, members, roles, status, limits', () async {
    final group = await groups.createGroup('Live Group $run');
    cleanupGroupIds.add(group.id);
    expect(group.isActive, isTrue);

    await groups.renameGroup(group.id, 'Live Group Renamed $run');
    final fetched = await groups.getGroup(group.id);
    expect(fetched.name, 'Live Group Renamed $run');
    expect(fetched.activeMemberCount, 0);

    final member = await users.createUser(
      name: 'Live Member',
      username: 'live_m_$run',
      password: _random(12),
    );
    cleanupUserIds.add(member.id);

    await groups.addMember(group.id, member.id);
    await expectLater(
      groups.addMember(group.id, member.id),
      throwsA(
        isA<RuleFailure>().having((f) => f.code, 'code', 'ALREADY_MEMBER'),
      ),
    );

    var members = await groups.listMembers(group.id);
    expect(members.single.username, 'live_m_$run');
    expect(members.single.isGroupAdmin, isFalse);

    await groups.setMemberAdmin(group.id, member.id, admin: true);
    await groups.setMemberActive(group.id, member.id, active: false);
    members = await groups.listMembers(group.id);
    expect(members.single.isGroupAdmin, isTrue);
    expect(members.single.isActive, isFalse);
    expect((await groups.getGroup(group.id)).activeMemberCount, 0);

    final memberships = await users.listMemberships(member.id);
    expect(memberships.single.groupName, 'Live Group Renamed $run');
    expect(memberships.single.isGroupAdmin, isTrue);

    await groups.setGroupActive(group.id, active: false);
    expect((await groups.getGroup(group.id)).isActive, isFalse);
    await expectLater(
      groups.addMember(group.id, cleanupUserIds.first),
      throwsA(
        isA<RuleFailure>().having((f) => f.code, 'code', 'GROUP_DISABLED'),
      ),
    );
    await groups.setGroupActive(group.id, active: true);

    await groups.removeMember(group.id, member.id);
    expect(await groups.listMembers(group.id), isEmpty);

    final all = await groups.listGroups();
    expect(all.any((g) => g.id == group.id), isTrue);
  }, skip: _skip);
}
