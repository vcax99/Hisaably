import '../../../core/constants/app_constants.dart';
import '../../auth/domain/user_context.dart';

class Group {
  const Group({
    required this.id,
    required this.name,
    required this.status,
    this.activeMemberCount = 0,
    this.totalMemberCount = 0,
  });

  /// Accepts a plain `groups` row, optionally with an embedded
  /// `group_members(status)` list used to count members.
  factory Group.fromJson(Map<String, dynamic> json) {
    final members = json['group_members'] as List<dynamic>?;
    return Group(
      id: json['id'] as String,
      name: json['name'] as String,
      status: json['status'] == 'ACTIVE'
          ? RecordStatus.active
          : RecordStatus.disabled,
      activeMemberCount:
          members?.where((m) => (m as Map)['status'] == 'ACTIVE').length ?? 0,
      totalMemberCount: members?.length ?? 0,
    );
  }

  final String id;
  final String name;
  final RecordStatus status;
  final int activeMemberCount;
  final int totalMemberCount;

  bool get isActive => status == RecordStatus.active;
  bool get isFull => activeMemberCount >= AppConstants.maxActiveMembersPerGroup;
}

class GroupMember {
  const GroupMember({
    required this.userId,
    required this.name,
    required this.username,
    required this.groupRole,
    required this.status,
    required this.profileActive,
  });

  factory GroupMember.fromJson(Map<String, dynamic> json) {
    final profile = json['profile'] as Map<String, dynamic>;
    return GroupMember(
      userId: json['user_id'] as String,
      name: profile['name'] as String,
      username: profile['username'] as String,
      groupRole: json['group_role'] == 'GROUP_ADMIN'
          ? GroupRole.groupAdmin
          : GroupRole.member,
      status: json['status'] == 'ACTIVE'
          ? RecordStatus.active
          : RecordStatus.disabled,
      profileActive: profile['status'] == 'ACTIVE',
    );
  }

  final String userId;
  final String name;
  final String username;
  final GroupRole groupRole;

  /// Membership status in this group.
  final RecordStatus status;

  /// Whether the user's whole account is active.
  final bool profileActive;

  bool get isGroupAdmin => groupRole == GroupRole.groupAdmin;
  bool get isActive => status == RecordStatus.active;
}
