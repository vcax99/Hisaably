import 'package:hisaably/core/errors/app_failure.dart';
import 'package:hisaably/features/auth/domain/user_context.dart';
import 'package:hisaably/features/groups/data/groups_repository.dart';
import 'package:hisaably/features/groups/domain/group.dart';
import 'package:hisaably/features/users/data/users_repository.dart';
import 'package:hisaably/features/users/domain/app_user.dart';

/// Shared in-memory backend for users + groups (mirrors server rules).
class FakeAdminBackend {
  final users = <String, AppUser>{};
  final groups = <String, Group>{};

  /// groupId -> userId -> member
  final members = <String, Map<String, GroupMember>>{};
  int _seq = 0;
  final calls = <String>[];

  String nextId(String prefix) => '$prefix-${++_seq}';

  AppUser addUser(
    String name,
    String username, {
    bool superAdmin = false,
    String? id,
  }) {
    final user = AppUser(
      id: id ?? nextId('u'),
      name: name,
      username: username,
      role: superAdmin ? AppRole.superAdmin : AppRole.user,
      status: RecordStatus.active,
    );
    users[user.id] = user;
    return user;
  }

  Group addGroup(String name, {String? id}) {
    final group = Group(
      id: id ?? nextId('g'),
      name: name,
      status: RecordStatus.active,
    );
    groups[group.id] = group;
    members[group.id] = {};
    return group;
  }

  void join(
    String groupId,
    String userId, {
    bool admin = false,
    bool active = true,
  }) {
    final u = users[userId]!;
    members[groupId]![userId] = GroupMember(
      userId: userId,
      name: u.name,
      username: u.username,
      groupRole: admin ? GroupRole.groupAdmin : GroupRole.member,
      status: active ? RecordStatus.active : RecordStatus.disabled,
      profileActive: u.isActive,
    );
  }

  Group withCounts(Group g) {
    final list = members[g.id]!.values;
    return Group(
      id: g.id,
      name: g.name,
      status: g.status,
      activeMemberCount: list.where((m) => m.isActive).length,
      totalMemberCount: list.length,
    );
  }
}

class FakeUsersRepository implements UsersRepository {
  FakeUsersRepository(this.db);

  final FakeAdminBackend db;

  @override
  Future<List<AppUser>> listUsers() async =>
      db.users.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  @override
  Future<AppUser> getUser(String userId) async =>
      db.users[userId] ?? (throw const NotFoundFailure('User not found.'));

  @override
  Future<List<UserMembership>> listMemberships(String userId) async => [
    for (final entry in db.members.entries)
      if (entry.value[userId] case final m?)
        UserMembership(
          groupId: entry.key,
          groupName: db.groups[entry.key]!.name,
          groupActive: db.groups[entry.key]!.isActive,
          isGroupAdmin: m.isGroupAdmin,
          active: m.isActive,
        ),
  ];

  @override
  Future<AppUser> createUser({
    required String name,
    required String username,
    required String password,
  }) async {
    db.calls.add('createUser:$username');
    if (db.users.values.any((u) => u.username == username)) {
      throw const RuleFailure(
        'USERNAME_TAKEN',
        'This username is already taken.',
      );
    }
    return db.addUser(name, username);
  }

  @override
  Future<void> resetPassword(String userId, String password) async =>
      db.calls.add('resetPassword:$userId');

  @override
  Future<void> setDisabled(String userId, {required bool disabled}) async {
    db.calls.add('setDisabled:$userId:$disabled');
    final u = db.users[userId]!;
    db.users[userId] = AppUser(
      id: u.id,
      name: u.name,
      username: u.username,
      role: u.role,
      status: disabled ? RecordStatus.disabled : RecordStatus.active,
    );
  }

  @override
  Future<void> deleteUser(String userId) async {
    db.calls.add('deleteUser:$userId');
    db.users.remove(userId);
    for (final m in db.members.values) {
      m.remove(userId);
    }
  }

  @override
  Future<void> rename(String userId, String name) async {
    final u = db.users[userId]!;
    db.users[userId] = AppUser(
      id: u.id,
      name: name,
      username: u.username,
      role: u.role,
      status: u.status,
    );
  }
}

class FakeGroupsRepository implements GroupsRepository {
  FakeGroupsRepository(this.db);

  final FakeAdminBackend db;

  @override
  Future<List<Group>> listGroups() async => [
    for (final g in db.groups.values) db.withCounts(g),
  ];

  @override
  Future<Group> getGroup(String groupId) async =>
      db.withCounts(db.groups[groupId] ?? (throw const NotFoundFailure()));

  @override
  Future<List<GroupMember>> listMembers(String groupId) async =>
      db.members[groupId]!.values.toList();

  @override
  Future<Group> createGroup(String name) async => db.addGroup(name);

  @override
  Future<void> renameGroup(String groupId, String name) async {
    final g = db.groups[groupId]!;
    db.groups[groupId] = Group(id: g.id, name: name, status: g.status);
  }

  @override
  Future<void> setGroupActive(String groupId, {required bool active}) async {
    final g = db.groups[groupId]!;
    db.groups[groupId] = Group(
      id: g.id,
      name: g.name,
      status: active ? RecordStatus.active : RecordStatus.disabled,
    );
  }

  @override
  Future<void> addMember(
    String groupId,
    String userId, {
    bool asAdmin = false,
  }) async {
    db.calls.add('addMember:$groupId:$userId');
    if (db.members[groupId]!.containsKey(userId)) {
      throw const RuleFailure(
        'ALREADY_MEMBER',
        'This user is already in the group.',
      );
    }
    if (db.withCounts(db.groups[groupId]!).isFull) {
      throw const RuleFailure(
        'GROUP_MEMBER_LIMIT',
        'A group can have at most 10 active members.',
      );
    }
    db.join(groupId, userId, admin: asAdmin);
  }

  @override
  Future<void> removeMember(String groupId, String userId) async {
    db.calls.add('removeMember:$groupId:$userId');
    db.members[groupId]!.remove(userId);
  }

  @override
  Future<void> setMemberActive(
    String groupId,
    String userId, {
    required bool active,
  }) async {
    db.calls.add('setMemberActive:$userId:$active');
    final m = db.members[groupId]![userId]!;
    db.join(groupId, userId, admin: m.isGroupAdmin, active: active);
  }

  @override
  Future<void> setMemberAdmin(
    String groupId,
    String userId, {
    required bool admin,
  }) async {
    db.calls.add('setMemberAdmin:$userId:$admin');
    final m = db.members[groupId]![userId]!;
    db.join(groupId, userId, admin: admin, active: m.isActive);
  }
}
