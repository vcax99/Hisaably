import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/error_mapper.dart';
import '../../../core/network/supabase_providers.dart';
import '../domain/app_user.dart';

/// User management (Super Admin). Reads use RLS-filtered selects; account
/// changes go through the `admin-users` Edge Function; renames via RPC.
/// Every method throws an [AppFailure] on error.
abstract interface class UsersRepository {
  Future<List<AppUser>> listUsers();

  Future<AppUser> getUser(String userId);

  Future<List<UserMembership>> listMemberships(String userId);

  Future<AppUser> createUser({
    required String name,
    required String username,
    required String password,
  });

  Future<void> resetPassword(String userId, String password);

  Future<void> setDisabled(String userId, {required bool disabled});

  Future<void> deleteUser(String userId);

  Future<void> rename(String userId, String name);
}

class SupabaseUsersRepository implements UsersRepository {
  SupabaseUsersRepository(this._client);

  final SupabaseClient _client;

  static const _columns = 'id, name, username, role, status, created_at';

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e, st) {
      throw mapError(e, st);
    }
  }

  Future<Map<String, dynamic>> _admin(Map<String, Object?> body) =>
      _guard(() async {
        final res = await _client.functions.invoke('admin-users', body: body);
        return (res.data as Map).cast<String, dynamic>();
      });

  @override
  Future<List<AppUser>> listUsers() => _guard(() async {
    final rows = await _client.rest
        .from('profiles')
        .select(_columns)
        .order('name', ascending: true);
    // Case-insensitive, independent of the database collation.
    return [for (final r in rows) AppUser.fromJson(r)]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  });

  @override
  Future<AppUser> getUser(String userId) => _guard(() async {
    final row = await _client.rest
        .from('profiles')
        .select(_columns)
        .eq('id', userId)
        .single();
    return AppUser.fromJson(row);
  });

  @override
  Future<List<UserMembership>> listMemberships(String userId) =>
      _guard(() async {
        final rows = await _client.rest
            .from('group_members')
            .select('group_id, group_role, status, group:groups(name, status)')
            .eq('user_id', userId);
        final list = [for (final r in rows) UserMembership.fromJson(r)];
        list.sort(
          (a, b) =>
              a.groupName.toLowerCase().compareTo(b.groupName.toLowerCase()),
        );
        return list;
      });

  @override
  Future<AppUser> createUser({
    required String name,
    required String username,
    required String password,
  }) async {
    final data = await _admin({
      'action': 'create_user',
      'name': name,
      'username': username,
      'password': password,
    });
    return AppUser.fromJson((data['user'] as Map).cast<String, dynamic>());
  }

  @override
  Future<void> resetPassword(String userId, String password) => _admin({
    'action': 'reset_password',
    'user_id': userId,
    'password': password,
  });

  @override
  Future<void> setDisabled(String userId, {required bool disabled}) => _admin({
    'action': disabled ? 'disable_user' : 'enable_user',
    'user_id': userId,
  });

  @override
  Future<void> deleteUser(String userId) =>
      _admin({'action': 'delete_user', 'user_id': userId});

  @override
  Future<void> rename(String userId, String name) => _guard(
    () => _client.rpc<dynamic>(
      'update_user_name',
      params: {'p_user_id': userId, 'p_name': name},
    ),
  );
}

final usersRepositoryProvider = Provider<UsersRepository>(
  (ref) => SupabaseUsersRepository(ref.watch(supabaseClientProvider)),
);
