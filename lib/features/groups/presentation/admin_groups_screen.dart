import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/async_value_view.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/status_chip.dart';
import '../../../routing/routes.dart';
import '../application/groups_providers.dart';
import '../data/groups_repository.dart';
import '../domain/group.dart';

/// Super Admin → Groups tab: every group with its active-member count.
class AdminGroupsScreen extends ConsumerWidget {
  const AdminGroupsScreen({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = await showTextInputDialog(
      context,
      title: 'New group',
      label: 'Group name',
      confirmLabel: 'Create',
      validator: (v) => v.length > 60 ? 'At most 60 characters' : null,
    );
    if (name == null || !context.mounted) return;
    Group? created;
    final ok = await runAction(
      context,
      () async =>
          created = await ref.read(groupsRepositoryProvider).createGroup(name),
      successMessage: 'Group created',
    );
    if (ok && context.mounted) {
      ref.invalidate(groupsListProvider);
      unawaited(context.push(Routes.adminGroup(created!.id)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupsListProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Groups'),
        actions: [
          IconButton(
            tooltip: 'New group',
            icon: const Icon(Icons.group_add_rounded),
            onPressed: () => _create(context, ref),
          ),
        ],
      ),
      body: AsyncValueView(
        value: groups,
        onRetry: () => ref.invalidate(groupsListProvider),
        data: (list) => RefreshIndicator(
          onRefresh: () => ref.refresh(groupsListProvider.future),
          child: list.isEmpty
              ? ListView(
                  children: [
                    const SizedBox(height: 120),
                    EmptyState(
                      icon: Icons.groups_outlined,
                      title: 'No groups yet',
                      message: 'Create a group, then add members to it.',
                      actionLabel: 'New group',
                      onAction: () => _create(context, ref),
                    ),
                  ],
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  itemCount: list.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (context, i) => GroupCard(
                    group: list[i],
                    onTap: () => context.push(Routes.adminGroup(list[i].id)),
                  ),
                ),
        ),
      ),
    );
  }
}

class GroupCard extends StatelessWidget {
  const GroupCard({
    super.key,
    required this.group,
    required this.onTap,
    this.badge,
  });

  final Group group;
  final VoidCallback onTap;

  /// Optional extra label, e.g. "Group Admin" in the member shell.
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    const max = AppConstants.maxActiveMembersPerGroup;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.elevated,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                ),
                child: Icon(
                  Icons.groups_rounded,
                  color: group.isActive
                      ? AppColors.accent
                      : AppColors.textMuted,
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(group.name, style: textTheme.titleMedium),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '${group.activeMemberCount}/$max active members',
                      style: textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              Wrap(
                spacing: AppSpacing.xs,
                children: [
                  ?badge,
                  if (!group.isActive)
                    const StatusChip('Disabled', tone: ChipTone.danger)
                  else if (group.isFull)
                    const StatusChip('Full', tone: ChipTone.warning),
                ],
              ),
              const SizedBox(width: AppSpacing.xs),
              const Icon(Icons.chevron_right, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
