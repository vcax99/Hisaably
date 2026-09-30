import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../data/auth_repository.dart';
import '../domain/user_context.dart';

sealed class SessionState {
  const SessionState();
}

class SessionSignedOut extends SessionState {
  const SessionSignedOut();
}

class SessionSignedIn extends SessionState {
  const SessionSignedIn(this.context, {this.offline = false});

  final UserContext context;

  /// True when the server couldn't be reached and the last cached context is
  /// being used. The server still re-checks everything on each request.
  final bool offline;
}

/// Signed-in user id from Supabase Auth (null when signed out).
final authUserIdProvider = StreamProvider<String?>(
  (ref) => ref.watch(authRepositoryProvider).watchUserId(),
);

/// One-shot message for the login screen (e.g. "account disabled").
class AuthNotice extends Notifier<String?> {
  @override
  String? build() => null;

  void show(String message) => state = message;

  void clear() => state = null;
}

final authNoticeProvider = NotifierProvider<AuthNotice, String?>(
  AuthNotice.new,
);

/// Session → profile → role → status → memberships, in the order the spec
/// requires. Routing is derived from this provider.
class SessionController extends AsyncNotifier<SessionState> {
  DateTime? _lastRefresh;

  AuthRepository get _repo => ref.read(authRepositoryProvider);

  @override
  Future<SessionState> build() async {
    final userId = await ref.watch(authUserIdProvider.future);
    if (userId == null) return const SessionSignedOut();

    try {
      final context = await _repo.fetchContext();
      if (!context.profile.isActive) {
        return await _forceSignOut(const AccountDisabledFailure());
      }
      _lastRefresh = DateTime.now();
      return SessionSignedIn(context);
    } on NetworkFailure {
      // Offline start-up: allow the cached context of this same user (never
      // a disabled one). Anything privileged is still enforced server-side.
      final cached = _repo.cachedContext(userId);
      if (cached != null && cached.profile.isActive) {
        return SessionSignedIn(cached, offline: true);
      }
      rethrow;
    } on AccountDisabledFailure catch (f) {
      return _forceSignOut(f);
    } on SessionExpiredFailure catch (f) {
      return _forceSignOut(f);
    }
  }

  Future<SessionState> _forceSignOut(AppFailure reason) async {
    ref.read(authNoticeProvider.notifier).show(reason.message);
    await _repo.signOut();
    return const SessionSignedOut();
  }

  /// Throws an [AppFailure] for the login screen to show.
  Future<void> signIn({
    required String username,
    required String password,
  }) async {
    ref.read(authNoticeProvider.notifier).clear();
    await _repo.signIn(username: username, password: password);
    // authUserIdProvider emits the new user id → build() loads the context.
  }

  Future<void> signOut() => _repo.signOut();

  /// Re-checks profile/role/memberships (e.g. on app resume) so a disabled
  /// account or a role change takes effect quickly. Throttled.
  void refresh({bool force = false}) {
    if (state.value is! SessionSignedIn) return;
    final last = _lastRefresh;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 30)) {
      return;
    }
    ref.invalidateSelf();
  }
}

final sessionControllerProvider =
    AsyncNotifierProvider<SessionController, SessionState>(
      SessionController.new,
    );

/// Convenience: the current user's context, or null when signed out/loading.
final currentUserContextProvider = Provider<UserContext?>((ref) {
  final session = ref.watch(sessionControllerProvider).value;
  return session is SessionSignedIn ? session.context : null;
});
