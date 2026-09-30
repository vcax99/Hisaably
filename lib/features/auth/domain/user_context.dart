/// The signed-in user's profile and group memberships, as returned by the
/// `get_my_context` RPC. The server is authoritative; this is only used for
/// routing and UX.
enum AppRole { superAdmin, user }

enum RecordStatus { active, disabled }

enum GroupRole { groupAdmin, member }

AppRole _role(Object? v) =>
    v == 'SUPER_ADMIN' ? AppRole.superAdmin : AppRole.user;
RecordStatus _status(Object? v) =>
    v == 'ACTIVE' ? RecordStatus.active : RecordStatus.disabled;
GroupRole _groupRole(Object? v) =>
    v == 'GROUP_ADMIN' ? GroupRole.groupAdmin : GroupRole.member;

String _roleName(AppRole r) => r == AppRole.superAdmin ? 'SUPER_ADMIN' : 'USER';
String _statusName(RecordStatus s) =>
    s == RecordStatus.active ? 'ACTIVE' : 'DISABLED';
String _groupRoleName(GroupRole r) =>
    r == GroupRole.groupAdmin ? 'GROUP_ADMIN' : 'MEMBER';

class UserProfile {
  const UserProfile({
    required this.id,
    required this.name,
    required this.username,
    required this.role,
    required this.status,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    id: json['id'] as String,
    name: json['name'] as String,
    username: json['username'] as String,
    role: _role(json['role']),
    status: _status(json['status']),
  );

  final String id;
  final String name;
  final String username;
  final AppRole role;
  final RecordStatus status;

  bool get isSuperAdmin => role == AppRole.superAdmin;
  bool get isActive => status == RecordStatus.active;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'username': username,
    'role': _roleName(role),
    'status': _statusName(status),
  };
}

class GroupMembership {
  const GroupMembership({
    required this.groupId,
    required this.groupName,
    required this.groupStatus,
    required this.groupRole,
    required this.membershipStatus,
  });

  factory GroupMembership.fromJson(Map<String, dynamic> json) =>
      GroupMembership(
        groupId: json['group_id'] as String,
        groupName: json['group_name'] as String,
        groupStatus: _status(json['group_status']),
        groupRole: _groupRole(json['group_role']),
        membershipStatus: _status(json['membership_status']),
      );

  final String groupId;
  final String groupName;
  final RecordStatus groupStatus;
  final GroupRole groupRole;
  final RecordStatus membershipStatus;

  /// Usable membership: both the group and the membership are active.
  bool get isActive =>
      groupStatus == RecordStatus.active &&
      membershipStatus == RecordStatus.active;

  bool get isGroupAdmin => isActive && groupRole == GroupRole.groupAdmin;

  Map<String, dynamic> toJson() => {
    'group_id': groupId,
    'group_name': groupName,
    'group_status': _statusName(groupStatus),
    'group_role': _groupRoleName(groupRole),
    'membership_status': _statusName(membershipStatus),
  };
}

class UserContext {
  const UserContext({required this.profile, required this.memberships});

  factory UserContext.fromJson(Map<String, dynamic> json) => UserContext(
    profile: UserProfile.fromJson(json['profile'] as Map<String, dynamic>),
    memberships: [
      for (final m in (json['memberships'] as List<dynamic>? ?? const []))
        GroupMembership.fromJson(m as Map<String, dynamic>),
    ],
  );

  final UserProfile profile;
  final List<GroupMembership> memberships;

  List<GroupMembership> get activeMemberships =>
      memberships.where((m) => m.isActive).toList(growable: false);

  bool isGroupAdminOf(String groupId) =>
      memberships.any((m) => m.groupId == groupId && m.isGroupAdmin);

  Map<String, dynamic> toJson() => {
    'profile': profile.toJson(),
    'memberships': [for (final m in memberships) m.toJson()],
  };
}
