import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/async_value_view.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/status_chip.dart';
import '../../auth/application/session_controller.dart';
import '../../users/application/users_providers.dart';
import '../../users/presentation/users_screen.dart' show UserAvatar;
import '../application/groups_providers.dart';
import '../data/groups_repository.dart';
import '../domain/group.dart';

/// What the current viewer may do in a group. UX only — every action is
/// enforced again by the server RPCs.
class GroupPermissions {
  const GroupPermissions({
    required this.isSuperAdmin,
    required this.isGroupAdmin,
  });

  final bool isSuperAdmin;
  final bool isGroupAdmin;

  bool get canRename => isSuperAdmin || isGroupAdmin;
  bool get canChangeGroupStatus => isSuperAdmin;
  bool get canAddOrRemove => isSuperAdmin;
  bool get canChangeRoles => isSuperAdmin;

  /// Super Admin: anyone. Group Admin: plain members other than themselves.
  bool canToggleMember(GroupMember m, String? viewerId) {
    if (isSuperAdmin) return true;
    return isGroupAdmin && !m.isGroupAdmin && m.userId != viewerId;
  }
}

class GroupDetailScreen extends ConsumerWidget {
  const GroupDetailScreen({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = ref.watch(groupProvider(groupId));
    return Scaffold(
      appBar: AppBar(title: Text(group.value?.name ?? 'Group')),
      body: AsyncValueView(
        value: group,
        onRetry: () => ref.invalidate(groupProvider(groupId)),
        data: (g) => _GroupDetailBody(group: g),
      ),
    );
  }
}

class _GroupDetailBody extends ConsumerWidget {
  const _GroupDetailBody({required this.group});

  final Group group;

  GroupsRepository _repo(WidgetRef ref) => ref.read(groupsRepositoryProvider);

  void _refresh(WidgetRef ref, [String? userId]) {
    invalidateGroup(ref, group.id);
    if (userId != null) ref.invalidate(userMembershipsProvider(userId));
    // The viewer's own memberships/roles may have changed.
    ref.read(sessionControllerProvider.notifier).refresh(force: true);
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final name = await showTextInputDialog(
      context,
      title: 'Rename group',
      label: 'Group name',
      confirmLabel: 'Save',
      initialValue: group.name,
      validator: (v) => v.length > 60 ? 'At most 60 characters' : null,
    );
    if (name == null || name == group.name || !context.mounted) return;
    final ok = await runAction(
      context,
      () => _repo(ref).renameGroup(group.id, name),
      successMessage: 'Group renamed',
    );
    if (ok) _refresh(ref);
  }

  Future<void> _toggleGroup(BuildContext context, WidgetRef ref) async {
    final disabling = group.isActive;
    final confirmed = await showConfirmDialog(
      context,
      title: disabling ? 'Disable ${group.name}?' : 'Enable ${group.name}?',
      message: disabling
          ? 'Members will lose access to this group until it is enabled '
                'again. Its transactions are kept.'
          : 'Active members will be able to use this group again.',
      confirmLabel: disabling ? 'Disable' : 'Enable',
      destructive: disabling,
    );
    if (!confirmed || !context.mounted) return;
    final ok = await runAction(
      context,
      () => _repo(ref).setGroupActive(group.id, active: !disabling),
      successMessage: disabling ? 'Group disabled' : 'Group enabled',
    );
    if (ok) _refresh(ref);
  }

  Future<void> _addMember(
    BuildContext context,
    WidgetRef ref,
    List<GroupMember> current,
  ) async {
    final existing = {for (final m in current) m.userId};
    final userId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      // Cover the bottom navigation bar like other full sheets.
      useRootNavigator: true,
      builder: (_) => _AddMemberSheet(excludedUserIds: existing),
    );
    if (userId == null || !context.mounted) return;
    final ok = await runAction(
      context,
      () => _repo(ref).addMember(group.id, userId),
      successMessage: 'Member added',
    );
    if (ok) _refresh(ref, userId);
  }

  Future<void> _memberAction(
    BuildContext context,
    WidgetRef ref,
    GroupMember m,
    _MemberAction action,
  ) async {
    final repo = _repo(ref);
    switch (action) {
      case _MemberAction.makeAdmin || _MemberAction.removeAdmin:
        final makeAdmin = action == _MemberAction.makeAdmin;
        final ok = await runAction(
          context,
          () => repo.setMemberAdmin(group.id, m.userId, admin: makeAdmin),
          successMessage: makeAdmin
              ? '${m.name} is now a Group Admin'
              : '${m.name} is now a member',
        );
        if (ok) _refresh(ref, m.userId);
      case _MemberAction.disable || _MemberAction.enable:
        final enable = action == _MemberAction.enable;
        if (!enable) {
          final confirmed = await showConfirmDialog(
            context,
            title: 'Disable ${m.name} in this group?',
            message:
                '${m.name} will lose access to ${group.name} until enabled again.',
            confirmLabel: 'Disable',
            destructive: true,
          );
          if (!confirmed || !context.mounted) return;
        }
        final ok = await runAction(
          context,
          () => repo.setMemberActive(group.id, m.userId, active: enable),
          successMessage: enable ? '${m.name} enabled' : '${m.name} disabled',
        );
        if (ok) _refresh(ref, m.userId);
      case _MemberAction.remove:
        final confirmed = await showConfirmDialog(
          context,
          title: 'Remove ${m.name}?',
          message:
              '${m.name} will be removed from ${group.name}. Their account '
              'and the group\'s transactions are not affected.',
          confirmLabel: 'Remove',
          destructive: true,
        );
        if (!confirmed || !context.mounted) return;
        final ok = await runAction(
          context,
          () => repo.removeMember(group.id, m.userId),
          successMessage: '${m.name} removed',
        );
        if (ok) _refresh(ref, m.userId);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userContext = ref.watch(currentUserContextProvider);
    final viewerId = userContext?.profile.id;
    final perms = GroupPermissions(
      isSuperAdmin: userContext?.profile.isSuperAdmin ?? false,
      isGroupAdmin: userContext?.isGroupAdminOf(group.id) ?? false,
    );
    final members = ref.watch(groupMembersProvider(group.id));
    final textTheme = Theme.of(context).textTheme;
    const max = AppConstants.maxActiveMembersPerGroup;

    return RefreshIndicator(
      onRefresh: () async => invalidateGroup(ref, group.id),
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(group.name, style: textTheme.titleLarge),
                      ),
                      StatusChip(
                        group.isActive ? 'Active' : 'Disabled',
                        tone: group.isActive
                            ? ChipTone.accent
                            : ChipTone.danger,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    '${group.activeMemberCount} of $max active members',
                    style: textTheme.bodyMedium,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: group.activeMemberCount / max,
                      minHeight: 6,
                      backgroundColor: AppColors.elevated,
                      color: group.isFull
                          ? AppColors.warning
                          : AppColors.accent,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (perms.canRename || perms.canChangeGroupStatus) ...[
            const SizedBox(height: AppSpacing.md),
            Card(
              child: Column(
                children: [
                  if (perms.canRename)
                    ListTile(
                      leading: const Icon(Icons.edit_outlined),
                      title: const Text('Rename group'),
                      onTap: () => _rename(context, ref),
                    ),
                  if (perms.canChangeGroupStatus)
                    ListTile(
                      leading: Icon(
                        group.isActive
                            ? Icons.block_rounded
                            : Icons.check_circle_outline_rounded,
                        color: group.isActive ? AppColors.warning : null,
                      ),
                      title: Text(
                        group.isActive ? 'Disable group' : 'Enable group',
                      ),
                      onTap: () => _toggleGroup(context, ref),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          Row(
            children: [
              Expanded(child: Text('Members', style: textTheme.labelLarge)),
              if (perms.canAddOrRemove)
                TextButton.icon(
                  onPressed: group.isActive && !group.isFull && members.hasValue
                      ? () => _addMember(context, ref, members.requireValue)
                      : null,
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: 20),
                  label: const Text('Add member'),
                ),
            ],
          ),
          if (perms.canAddOrRemove && group.isFull)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                'This group has $max active members, the maximum. Disable or '
                'remove someone to add another member.',
                style: textTheme.bodySmall,
              ),
            ),
          AsyncValueView(
            value: members,
            onRetry: () => ref.invalidate(groupMembersProvider(group.id)),
            data: (list) => Card(
              child: list.isEmpty
                  ? const ListTile(title: Text('No members yet'))
                  : Column(
                      children: [
                        for (final (i, m) in list.indexed) ...[
                          if (i > 0) const Divider(indent: 72),
                          _MemberTile(
                            member: m,
                            isViewer: m.userId == viewerId,
                            actions: _actionsFor(m, perms, viewerId),
                            onAction: (a) => _memberAction(context, ref, m, a),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  List<_MemberAction> _actionsFor(
    GroupMember m,
    GroupPermissions perms,
    String? viewerId,
  ) => [
    if (perms.canChangeRoles)
      m.isGroupAdmin ? _MemberAction.removeAdmin : _MemberAction.makeAdmin,
    if (perms.canToggleMember(m, viewerId))
      m.isActive ? _MemberAction.disable : _MemberAction.enable,
    if (perms.canAddOrRemove) _MemberAction.remove,
  ];
}

enum _MemberAction {
  makeAdmin('Make Group Admin', Icons.shield_outlined),
  removeAdmin('Remove Group Admin', Icons.remove_moderator_outlined),
  disable('Disable in group', Icons.block_rounded),
  enable('Enable in group', Icons.check_circle_outline_rounded),
  remove('Remove from group', Icons.person_remove_outlined);

  const _MemberAction(this.label, this.icon);

  final String label;
  final IconData icon;
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.member,
    required this.isViewer,
    required this.actions,
    required this.onAction,
  });

  final GroupMember member;
  final bool isViewer;
  final List<_MemberAction> actions;
  final ValueChanged<_MemberAction> onAction;

  @override
  Widget build(BuildContext context) {
    final dimmed = !member.isActive || !member.profileActive;
    return ListTile(
      minTileHeight: 64,
      leading: UserAvatar(name: member.name, dimmed: dimmed),
      title: Text(
        isViewer ? '${member.name} (you)' : member.name,
        style: TextStyle(
          color: dimmed ? AppColors.textMuted : AppColors.textPrimary,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.xs),
        child: Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('@${member.username}'),
            if (member.isGroupAdmin)
              const StatusChip('Group Admin', tone: ChipTone.accent),
            if (!member.isActive)
              const StatusChip('Disabled', tone: ChipTone.danger),
            if (!member.profileActive)
              const StatusChip('Account disabled', tone: ChipTone.warning),
          ],
        ),
      ),
      trailing: actions.isEmpty
          ? null
          : PopupMenuButton<_MemberAction>(
              tooltip: 'Member actions',
              color: AppColors.elevated,
              onSelected: onAction,
              itemBuilder: (_) => [
                for (final a in actions)
                  PopupMenuItem(
                    value: a,
                    child: Row(
                      children: [
                        Icon(
                          a.icon,
                          size: 20,
                          color: a == _MemberAction.remove
                              ? AppColors.expense
                              : AppColors.textSecondary,
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Flexible(
                          child: Text(
                            a.label,
                            style: a == _MemberAction.remove
                                ? const TextStyle(color: AppColors.expense)
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Picks an existing, active user who isn't in the group yet.
class _AddMemberSheet extends ConsumerStatefulWidget {
  const _AddMemberSheet({required this.excludedUserIds});

  final Set<String> excludedUserIds;

  @override
  ConsumerState<_AddMemberSheet> createState() => _AddMemberSheetState();
}

class _AddMemberSheetState extends ConsumerState<_AddMemberSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(usersListProvider);
    final bottomInset =
        MediaQuery.viewInsetsOf(context).bottom +
        MediaQuery.viewPaddingOf(context).bottom;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          bottomInset,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Add member', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.md),
            TextField(
              decoration: const InputDecoration(
                hintText: 'Search users',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: AsyncValueView(
                value: users,
                onRetry: () => ref.invalidate(usersListProvider),
                data: (list) {
                  final candidates = list
                      .where(
                        (u) =>
                            u.isActive &&
                            !widget.excludedUserIds.contains(u.id) &&
                            u.matches(_query),
                      )
                      .toList();
                  if (candidates.isEmpty) {
                    return Center(
                      child: Text(
                        'No available users. Create users in the Users tab first.',
                        style: Theme.of(context).textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: candidates.length,
                    itemBuilder: (context, i) {
                      final u = candidates[i];
                      return ListTile(
                        minTileHeight: 60,
                        leading: UserAvatar(name: u.name),
                        title: Text(u.name),
                        subtitle: Text('@${u.username}'),
                        onTap: () => Navigator.of(context).pop(u.id),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
