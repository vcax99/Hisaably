import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/error_mapper.dart';
import '../../../core/network/supabase_providers.dart';
import '../domain/group.dart';

/// Groups and memberships. Reads are RLS-filtered selects (a member only
/// sees their own groups); all writes go through permission-checked RPCs.
/// Every method throws an [AppFailure] on error.
abstract interface class GroupsRepository {
  Future<List<Group>> listGroups();

  Future<Group> getGroup(String groupId);

  Future<List<GroupMember>> listMembers(String groupId);

  Future<Group> createGroup(String name);

  Future<void> renameGroup(String groupId, String name);

  Future<void> setGroupActive(String groupId, {required bool active});

  Future<void> addMember(String groupId, String userId, {bool asAdmin});

  Future<void> removeMember(String groupId, String userId);

  Future<void> setMemberActive(
    String groupId,
    String userId, {
    required bool active,
  });

  Future<void> setMemberAdmin(
    String groupId,
    String userId, {
    required bool admin,
  });
}

class SupabaseGroupsRepository implements GroupsRepository {
  SupabaseGroupsRepository(this._client);

  final SupabaseClient _client;

  static const _groupColumns = 'id, name, status, group_members(status)';

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e, st) {
      throw mapError(e, st);
    }
  }

  Future<void> _rpc(String fn, Map<String, Object?> params) =>
      _guard(() => _client.rpc<dynamic>(fn, params: params));

  @override
  Future<List<Group>> listGroups() => _guard(() async {
    final rows = await _client
        .from('groups')
        .select(_groupColumns)
        .order('name', ascending: true);
    return [for (final r in rows) Group.fromJson(r)]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  });

  @override
  Future<Group> getGroup(String groupId) => _guard(() async {
    final row = await _client
        .from('groups')
        .select(_groupColumns)
        .eq('id', groupId)
        .single();
    return Group.fromJson(row);
  });

  @override
  Future<List<GroupMember>> listMembers(String groupId) => _guard(() async {
    final rows = await _client
        .from('group_members')
        .select(
          'user_id, group_role, status, joined_at, '
          'profile:profiles(name, username, status)',
        )
        .eq('group_id', groupId)
        .order('joined_at', ascending: true);
    final members = [for (final r in rows) GroupMember.fromJson(r)];
    // Group Admins first, then active members, then by name.
    members.sort((a, b) {
      if (a.isGroupAdmin != b.isGroupAdmin) return a.isGroupAdmin ? -1 : 1;
      if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return members;
  });

  @override
  Future<Group> createGroup(String name) => _guard(() async {
    final row = await _client.rpc<Map<String, dynamic>>(
      'create_group',
      params: {'p_name': name},
    );
    return Group.fromJson(row);
  });

  @override
  Future<void> renameGroup(String groupId, String name) =>
      _rpc('rename_group', {'p_group_id': groupId, 'p_name': name});

  @override
  Future<void> setGroupActive(String groupId, {required bool active}) => _rpc(
    'set_group_status',
    {'p_group_id': groupId, 'p_status': active ? 'ACTIVE' : 'DISABLED'},
  );

  @override
  Future<void> addMember(
    String groupId,
    String userId, {
    bool asAdmin = false,
  }) => _rpc('add_group_member', {
    'p_group_id': groupId,
    'p_user_id': userId,
    'p_group_role': asAdmin ? 'GROUP_ADMIN' : 'MEMBER',
  });

  @override
  Future<void> removeMember(String groupId, String userId) =>
      _rpc('remove_group_member', {'p_group_id': groupId, 'p_user_id': userId});

  @override
  Future<void> setMemberActive(
    String groupId,
    String userId, {
    required bool active,
  }) => _rpc('set_group_member_status', {
    'p_group_id': groupId,
    'p_user_id': userId,
    'p_status': active ? 'ACTIVE' : 'DISABLED',
  });

  @override
  Future<void> setMemberAdmin(
    String groupId,
    String userId, {
    required bool admin,
  }) => _rpc('set_group_member_role', {
    'p_group_id': groupId,
    'p_user_id': userId,
    'p_group_role': admin ? 'GROUP_ADMIN' : 'MEMBER',
  });
}

final groupsRepositoryProvider = Provider<GroupsRepository>(
  (ref) => SupabaseGroupsRepository(ref.watch(supabaseClientProvider)),
);
