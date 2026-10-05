import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/features/auth/domain/user_context.dart';
import 'package:hisaably/features/auth/domain/username.dart';

void main() {
  test('parses get_my_context JSON and round-trips for the cache', () {
    final json = {
      'profile': {
        'id': 'u1',
        'name': 'Asha',
        'username': 'asha',
        'role': 'USER',
        'status': 'ACTIVE',
      },
      'memberships': [
        {
          'group_id': 'g1',
          'group_name': 'Roomies',
          'group_status': 'ACTIVE',
          'group_role': 'GROUP_ADMIN',
          'membership_status': 'ACTIVE',
        },
        {
          'group_id': 'g2',
          'group_name': 'Trip',
          'group_status': 'DISABLED',
          'group_role': 'MEMBER',
          'membership_status': 'ACTIVE',
        },
      ],
    };
    final ctx = UserContext.fromJson(json);
    expect(ctx.profile.isSuperAdmin, isFalse);
    expect(ctx.profile.isActive, isTrue);
    expect(ctx.activeMemberships.map((m) => m.groupId), ['g1']);
    expect(ctx.isGroupAdminOf('g1'), isTrue);
    expect(ctx.isGroupAdminOf('g2'), isFalse);
    expect(UserContext.fromJson(ctx.toJson()).toJson(), ctx.toJson());
  });

  test('username maps to the synthetic auth email', () {
    expect(Username.toAuthEmail(' VCAX99 '), 'vcax99@users.hisaably.invalid');
    expect(Username.isValid('rahul.k'), isTrue);
    expect(Username.isValid('ab'), isFalse);
    expect(Username.isValid('.rahul'), isFalse);
    expect(Username.isValid('ra hul'), isFalse);
  });
}
