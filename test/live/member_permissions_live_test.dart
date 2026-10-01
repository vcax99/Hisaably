// Live test: what a Group Admin, a plain member and an outsider can do via
// GroupsRepository against the dev backend. Run with scripts/run_live_tests.sh.
@Tags(['live'])
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/errors/app_failure.dart';
import 'package:hisaably/features/auth/domain/username.dart';
import 'package:hisaably/features/groups/data/groups_repository.dart';
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
  final run = _random(6);
  final password = _random(16);
  final ids = <String, String>{}; // role -> user id
  late String groupId;

  Future<GroupsRepository> repoAs(String role) async {
    final client = SupabaseClient(
      _url!,
      _publishable!,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    await client.auth.signInWithPassword(
      email: Username.toAuthEmail('live_${role}_$run'),
      password: password,
    );
    return SupabaseGroupsRepository(client);
  }

  Matcher forbidden() => throwsA(isA<PermissionFailure>());

  setUpAll(() async {
    if (_skip != null) return;
    admin = SupabaseClient(
      _url!,
      _service!,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    for (final role in ['ga', 'ga2', 'm1', 'out']) {
      final res = await admin.auth.admin.createUser(
        AdminUserAttributes(
          email: Username.toAuthEmail('live_${role}_$run'),
          password: password,
          emailConfirm: true,
          userMetadata: {'username': 'live_${role}_$run', 'name': 'Live $role'},
        ),
      );
      ids[role] = res.user!.id;
    }
    final group = await admin
        .from('groups')
        .insert({'name': 'Live Perm $run'})
        .select('id')
        .single();
    groupId = group['id'] as String;
    await admin.from('group_members').insert([
      {'group_id': groupId, 'user_id': ids['ga'], 'group_role': 'GROUP_ADMIN'},
      {'group_id': groupId, 'user_id': ids['ga2'], 'group_role': 'GROUP_ADMIN'},
      {'group_id': groupId, 'user_id': ids['m1'], 'group_role': 'MEMBER'},
    ]);
  });

  tearDownAll(() async {
    if (_skip != null) return;
    await admin.from('group_members').delete().eq('group_id', groupId);
    await admin.from('group_categories').delete().eq('group_id', groupId);
    await admin.from('groups').delete().eq('id', groupId);
    for (final id in ids.values) {
      await admin.auth.admin.deleteUser(id);
    }
  });

  test('group admin: rename + toggle plain members; nothing else', () async {
    final ga = await repoAs('ga');
    final groups = await ga.listGroups();
    expect(groups.map((g) => g.id), [groupId]);

    await ga.renameGroup(groupId, 'Live Perm Renamed $run');
    await ga.setMemberActive(groupId, ids['m1']!, active: false);
    await ga.setMemberActive(groupId, ids['m1']!, active: true);

    await expectLater(
      ga.setMemberActive(groupId, ids['ga']!, active: false),
      forbidden(),
      reason: 'cannot disable self',
    );
    await expectLater(
      ga.setMemberActive(groupId, ids['ga2']!, active: false),
      forbidden(),
      reason: 'cannot disable another Group Admin',
    );
    await expectLater(ga.addMember(groupId, ids['out']!), forbidden());
    await expectLater(ga.removeMember(groupId, ids['m1']!), forbidden());
    await expectLater(
      ga.setMemberAdmin(groupId, ids['m1']!, admin: true),
      forbidden(),
    );
    await expectLater(ga.setGroupActive(groupId, active: false), forbidden());
  }, skip: _skip);

  test('member: sees group and members, cannot change anything', () async {
    final m1 = await repoAs('m1');
    expect((await m1.listGroups()).map((g) => g.id), [groupId]);
    expect(await m1.listMembers(groupId), hasLength(3));
    await expectLater(m1.renameGroup(groupId, 'Nope'), forbidden());
    await expectLater(
      m1.setMemberActive(groupId, ids['ga']!, active: false),
      forbidden(),
    );
  }, skip: _skip);

  test('disabled member loses the group; outsider sees nothing', () async {
    final ga = await repoAs('ga');
    await ga.setMemberActive(groupId, ids['m1']!, active: false);
    final m1 = await repoAs('m1');
    expect(await m1.listGroups(), isEmpty);
    await ga.setMemberActive(groupId, ids['m1']!, active: true);

    final out = await repoAs('out');
    expect(await out.listGroups(), isEmpty);
    expect(await out.listMembers(groupId), isEmpty);
  }, skip: _skip);
}
