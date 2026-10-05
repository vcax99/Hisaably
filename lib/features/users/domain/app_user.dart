import '../../auth/domain/user_context.dart';

/// A user as seen in User Management (Super Admin).
class AppUser {
  const AppUser({
    required this.id,
    required this.name,
    required this.username,
    required this.role,
    required this.status,
    this.createdAt,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
    id: json['id'] as String,
    name: json['name'] as String,
    username: json['username'] as String,
    role: json['role'] == 'SUPER_ADMIN' ? AppRole.superAdmin : AppRole.user,
    status: json['status'] == 'ACTIVE'
        ? RecordStatus.active
        : RecordStatus.disabled,
    createdAt: json['created_at'] == null
        ? null
        : DateTime.parse(json['created_at'] as String),
  );

  final String id;
  final String name;
  final String username;
  final AppRole role;
  final RecordStatus status;
  final DateTime? createdAt;

  bool get isActive => status == RecordStatus.active;
  bool get isSuperAdmin => role == AppRole.superAdmin;

  /// Case-insensitive match on name or username (for the search box).
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) || username.contains(q);
  }
}

/// One of a user's group memberships, as shown on the user detail screen.
class UserMembership {
  const UserMembership({
    required this.groupId,
    required this.groupName,
    required this.groupActive,
    required this.isGroupAdmin,
    required this.active,
  });

  factory UserMembership.fromJson(Map<String, dynamic> json) {
    final group = json['group'] as Map<String, dynamic>;
    return UserMembership(
      groupId: json['group_id'] as String,
      groupName: group['name'] as String,
      groupActive: group['status'] == 'ACTIVE',
      isGroupAdmin: json['group_role'] == 'GROUP_ADMIN',
      active: json['status'] == 'ACTIVE',
    );
  }

  final String groupId;
  final String groupName;
  final bool groupActive;
  final bool isGroupAdmin;
  final bool active;
}
