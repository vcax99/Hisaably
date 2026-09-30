import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/application/session_controller.dart';
import 'routes.dart';

/// Pure routing rule (unit-tested). UI routing is only UX: every permission is
/// enforced again by RLS/RPCs on the server.
String? sessionRedirect(AsyncValue<SessionState> session, String location) {
  final value = session.value;
  if (value == null) {
    // First load, or an error before any session was known.
    return location == Routes.splash ? null : Routes.splash;
  }

  switch (value) {
    case SessionSignedOut():
      return location == Routes.login ? null : Routes.login;
    case SessionSignedIn(:final context):
      final isAdmin = context.profile.isSuperAdmin;
      final home = isAdmin ? Routes.adminDashboard : Routes.memberDashboard;
      if (location == Routes.login || location == Routes.splash) return home;
      if (isAdmin && location.startsWith(Routes.memberPrefix)) return home;
      if (!isAdmin && location.startsWith(Routes.adminPrefix)) return home;
      return null;
  }
}
