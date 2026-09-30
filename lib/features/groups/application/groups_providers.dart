import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/groups_repository.dart';
import '../domain/group.dart';

final groupsListProvider = FutureProvider.autoDispose<List<Group>>(
  (ref) => ref.watch(groupsRepositoryProvider).listGroups(),
);

final groupProvider = FutureProvider.autoDispose.family<Group, String>(
  (ref, groupId) => ref.watch(groupsRepositoryProvider).getGroup(groupId),
);

final groupMembersProvider = FutureProvider.autoDispose
    .family<List<GroupMember>, String>(
      (ref, groupId) =>
          ref.watch(groupsRepositoryProvider).listMembers(groupId),
    );

/// Refresh everything that shows this group after a change.
void invalidateGroup(WidgetRef ref, String groupId) {
  ref
    ..invalidate(groupsListProvider)
    ..invalidate(groupProvider(groupId))
    ..invalidate(groupMembersProvider(groupId));
}
