import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/error_mapper.dart';
import '../../../core/network/supabase_providers.dart';
import '../domain/user_context.dart';
import '../domain/username.dart';

abstract interface class AuthRepository {
  /// Emits the signed-in user's id (or null) now and on every auth change.
  Stream<String?> watchUserId();

  String? get currentUserId;

  /// Throws an [AppFailure] (AuthFailure, AccountDisabledFailure, ...).
  Future<void> signIn({required String username, required String password});

  Future<void> signOut();

  /// Fresh context from the server. Throws an [AppFailure].
  Future<UserContext> fetchContext();

  /// Last context fetched for [userId] on this device, for offline start-up.
  UserContext? cachedContext(String userId);
}

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._client, this._cache);

  final SupabaseClient _client;
  final UserContextCache _cache;

  @override
  Stream<String?> watchUserId() async* {
    yield _client.auth.currentUser?.id;
    yield* _client.auth.onAuthStateChange.map((s) => s.session?.user.id);
  }

  @override
  String? get currentUserId => _client.auth.currentUser?.id;

  @override
  Future<void> signIn({
    required String username,
    required String password,
  }) async {
    try {
      await _client.auth.signInWithPassword(
        email: Username.toAuthEmail(username),
        password: password,
      );
    } catch (e, st) {
      throw mapError(e, st);
    }
  }

  @override
  Future<void> signOut() async {
    await _cache.clear();
    try {
      await _client.auth.signOut();
    } catch (_) {
      // Offline or already-invalid session: clear the local session anyway.
      await _client.auth.signOut(scope: SignOutScope.local);
    }
  }

  @override
  Future<UserContext> fetchContext() async {
    try {
      final data = await _client.rpc<Map<String, dynamic>>('get_my_context');
      final context = UserContext.fromJson(data);
      await _cache.save(context);
      return context;
    } catch (e, st) {
      throw mapError(e, st);
    }
  }

  @override
  UserContext? cachedContext(String userId) => _cache.load(userId);
}

/// Small non-secret cache (profile + memberships) so a signed-in user can open
/// the app offline. Server checks remain authoritative on every request.
class UserContextCache {
  UserContextCache(this._prefs);

  static const _key = 'auth.user_context.v1';
  final SharedPreferences _prefs;

  UserContext? load(String userId) {
    final raw = _prefs.getString(_key);
    if (raw == null) return null;
    try {
      final context = UserContext.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      return context.profile.id == userId ? context : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(UserContext context) =>
      _prefs.setString(_key, jsonEncode(context.toJson()));

  Future<void> clear() => _prefs.remove(_key);
}

final userContextCacheProvider = Provider<UserContextCache>(
  (ref) => UserContextCache(ref.watch(sharedPreferencesProvider)),
);

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => SupabaseAuthRepository(
    ref.watch(supabaseClientProvider),
    ref.watch(userContextCacheProvider),
  ),
);
