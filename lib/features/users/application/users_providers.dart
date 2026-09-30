import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/users_repository.dart';
import '../domain/app_user.dart';

final usersListProvider = FutureProvider.autoDispose<List<AppUser>>(
  (ref) => ref.watch(usersRepositoryProvider).listUsers(),
);

final userProvider = FutureProvider.autoDispose.family<AppUser, String>(
  (ref, userId) => ref.watch(usersRepositoryProvider).getUser(userId),
);

final userMembershipsProvider = FutureProvider.autoDispose
    .family<List<UserMembership>, String>(
      (ref, userId) =>
          ref.watch(usersRepositoryProvider).listMemberships(userId),
    );

/// Refresh everything that shows user data after a change.
void invalidateUser(WidgetRef ref, String userId) {
  ref
    ..invalidate(usersListProvider)
    ..invalidate(userProvider(userId))
    ..invalidate(userMembershipsProvider(userId));
}
