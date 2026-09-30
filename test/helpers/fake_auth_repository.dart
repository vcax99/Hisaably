import 'dart:async';

import 'package:hisaably/core/errors/app_failure.dart';
import 'package:hisaably/features/auth/data/auth_repository.dart';
import 'package:hisaably/features/auth/domain/user_context.dart';
import 'package:hisaably/features/auth/domain/username.dart';

UserContext buildContext({
  String id = 'user-1',
  String name = 'Asha',
  String username = 'asha',
  AppRole role = AppRole.user,
  RecordStatus status = RecordStatus.active,
  List<GroupMembership> memberships = const [
    GroupMembership(
      groupId: 'g1',
      groupName: 'Roomies',
      groupStatus: RecordStatus.active,
      groupRole: GroupRole.member,
      membershipStatus: RecordStatus.active,
    ),
  ],
}) => UserContext(
  profile: UserProfile(
    id: id,
    name: name,
    username: username,
    role: role,
    status: status,
  ),
  memberships: memberships,
);

final memberContext = buildContext();
final superAdminContext = buildContext(
  id: 'admin-1',
  name: 'Bikash',
  username: 'vcax99',
  role: AppRole.superAdmin,
  memberships: const [],
);

class FakeAccount {
  FakeAccount(this.password, this.context, {this.banned = false});

  final String password;
  UserContext context;
  bool banned;
}

/// In-memory AuthRepository for unit/widget tests (no network).
class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({Map<String, FakeAccount>? accounts, String? signedInAs})
    : accounts = accounts ?? {} {
    if (signedInAs != null) {
      _userId = this.accounts[signedInAs]!.context.profile.id;
    }
  }

  final Map<String, FakeAccount> accounts;
  final _changes = StreamController<String?>.broadcast();
  String? _userId;

  /// When set, fetchContext throws this instead of returning the account.
  AppFailure? fetchError;

  /// When set, fetchContext waits for this first (e.g. to hold the splash).
  Future<void>? fetchGate;
  UserContext? cache;
  int signOutCalls = 0;
  int fetchCalls = 0;

  FakeAccount? get _current =>
      accounts.values.where((a) => a.context.profile.id == _userId).firstOrNull;

  @override
  Stream<String?> watchUserId() async* {
    yield _userId;
    yield* _changes.stream;
  }

  @override
  String? get currentUserId => _userId;

  @override
  Future<void> signIn({
    required String username,
    required String password,
  }) async {
    final account = accounts[Username.normalize(username)];
    if (account == null || account.password != password) {
      throw const AuthFailure();
    }
    if (account.banned) throw const AccountDisabledFailure();
    _userId = account.context.profile.id;
    _changes.add(_userId);
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    cache = null;
    _userId = null;
    _changes.add(null);
  }

  @override
  Future<UserContext> fetchContext() async {
    fetchCalls++;
    if (fetchGate != null) await fetchGate;
    if (fetchError != null) throw fetchError!;
    final account = _current;
    if (account == null) throw const SessionExpiredFailure();
    cache = account.context;
    return account.context;
  }

  @override
  UserContext? cachedContext(String userId) =>
      cache?.profile.id == userId ? cache : null;
}
