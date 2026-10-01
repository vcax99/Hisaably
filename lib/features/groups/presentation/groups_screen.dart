import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/async_value_view.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/status_chip.dart';
import '../../../routing/routes.dart';
import '../../auth/application/session_controller.dart';
import '../application/groups_providers.dart';
import 'admin_groups_screen.dart' show GroupCard;

/// Member shell → Groups tab: the groups the user actively belongs to.
/// RLS already limits the list to active groups with an active membership.
class GroupsScreen extends ConsumerWidget {
  const GroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupsListProvider);
    final userContext = ref.watch(currentUserContextProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Groups')),
      body: AsyncValueView(
        value: groups,
        onRetry: () => ref.invalidate(groupsListProvider),
        data: (list) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(groupsListProvider);
            ref.read(sessionControllerProvider.notifier).refresh(force: true);
          },
          child: list.isEmpty
              ? ListView(
                  children: const [
                    SizedBox(height: 120),
                    EmptyState(
                      icon: Icons.groups_outlined,
                      title: 'You are not in any group yet',
                      message: 'Ask your administrator to add you to a group.',
                    ),
                  ],
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  itemCount: list.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (context, i) {
                    final group = list[i];
                    final isAdmin =
                        userContext?.isGroupAdminOf(group.id) ?? false;
                    return GroupCard(
                      group: group,
                      onTap: () => context.push(Routes.memberGroup(group.id)),
                      badge: isAdmin
                          ? const StatusChip(
                              'Group Admin',
                              tone: ChipTone.accent,
                            )
                          : null,
                    );
                  },
                ),
        ),
      ),
    );
  }
}
