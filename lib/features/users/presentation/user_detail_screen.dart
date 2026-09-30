import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/async_value_view.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/status_chip.dart';
import '../../../routing/routes.dart';
import '../../auth/application/session_controller.dart';
import '../../groups/application/groups_providers.dart';
import '../application/users_providers.dart';
import '../data/users_repository.dart';
import '../domain/app_user.dart';
import 'create_user_screen.dart' show validatePassword;
import 'users_screen.dart' show UserAvatar;

/// Super Admin → Users → one user: groups, rename, reset password,
/// disable/enable, delete.
class UserDetailScreen extends ConsumerWidget {
  const UserDetailScreen({super.key, required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(userProvider(userId));
    return Scaffold(
      appBar: AppBar(title: const Text('User')),
      body: AsyncValueView(
        value: user,
        onRetry: () => ref.invalidate(userProvider(userId)),
        data: (u) => _UserDetailBody(user: u),
      ),
    );
  }
}

class _UserDetailBody extends ConsumerWidget {
  const _UserDetailBody({required this.user});

  final AppUser user;

  UsersRepository _repo(WidgetRef ref) => ref.read(usersRepositoryProvider);

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final name = await showTextInputDialog(
      context,
      title: 'Rename user',
      label: 'Full name',
      confirmLabel: 'Save',
      initialValue: user.name,
      validator: (v) => v.length > 80 ? 'At most 80 characters' : null,
    );
    if (name == null || name == user.name || !context.mounted) return;
    final ok = await runAction(
      context,
      () => _repo(ref).rename(user.id, name),
      successMessage: 'Name updated',
    );
    if (ok) {
      invalidateUser(ref, user.id);
      if (ref.read(currentUserContextProvider)?.profile.id == user.id) {
        ref.read(sessionControllerProvider.notifier).refresh(force: true);
      }
    }
  }

  Future<void> _resetPassword(BuildContext context, WidgetRef ref) async {
    final password = await showTextInputDialog(
      context,
      title: 'Reset password',
      label: 'New password',
      confirmLabel: 'Reset',
      obscure: true,
      validator: validatePassword,
    );
    if (password == null || !context.mounted) return;
    await runAction(
      context,
      () => _repo(ref).resetPassword(user.id, password),
      successMessage:
          'Password reset. Share the new password with ${user.name}.',
    );
  }

  Future<void> _toggleDisabled(BuildContext context, WidgetRef ref) async {
    final disabling = user.isActive;
    final confirmed = await showConfirmDialog(
      context,
      title: disabling ? 'Disable ${user.name}?' : 'Enable ${user.name}?',
      message: disabling
          ? '${user.name} will be signed out and won\'t be able to sign in '
                'until enabled again. Their groups and transactions stay as they are.'
          : '${user.name} will be able to sign in again.',
      confirmLabel: disabling ? 'Disable' : 'Enable',
      destructive: disabling,
    );
    if (!confirmed || !context.mounted) return;
    final ok = await runAction(
      context,
      () => _repo(ref).setDisabled(user.id, disabled: disabling),
      successMessage: disabling ? 'User disabled' : 'User enabled',
    );
    if (ok) invalidateUser(ref, user.id);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete ${user.name}?',
      message:
          'This permanently deletes @${user.username} and removes them from '
          'all groups. They will no longer be able to sign in. Group '
          'transactions are not affected. This cannot be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    final ok = await runAction(
      context,
      () => _repo(ref).deleteUser(user.id),
      successMessage: 'User deleted',
    );
    if (ok) {
      ref.invalidate(usersListProvider);
      ref.invalidate(groupsListProvider);
      if (context.mounted) context.pop();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSelf = ref.watch(currentUserContextProvider)?.profile.id == user.id;
    final memberships = ref.watch(userMembershipsProvider(user.id));
    final textTheme = Theme.of(context).textTheme;

    return RefreshIndicator(
      onRefresh: () async => invalidateUser(ref, user.id),
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Row(
                children: [
                  UserAvatar(name: user.name, dimmed: !user.isActive),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(user.name, style: textTheme.titleMedium),
                        const SizedBox(height: AppSpacing.xs),
                        Text('@${user.username}', style: textTheme.bodyMedium),
                        const SizedBox(height: AppSpacing.sm),
                        Wrap(
                          spacing: AppSpacing.xs,
                          runSpacing: AppSpacing.xs,
                          children: [
                            if (user.isSuperAdmin)
                              const StatusChip(
                                'Super Admin',
                                tone: ChipTone.accent,
                              ),
                            StatusChip(
                              user.isActive ? 'Active' : 'Disabled',
                              tone: user.isActive
                                  ? ChipTone.neutral
                                  : ChipTone.danger,
                            ),
                            if (isSelf) const StatusChip('You'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text('Groups', style: textTheme.labelLarge),
          const SizedBox(height: AppSpacing.sm),
          AsyncValueView(
            value: memberships,
            onRetry: () => ref.invalidate(userMembershipsProvider(user.id)),
            data: (list) => Card(
              child: list.isEmpty
                  ? const ListTile(title: Text('Not in any group yet'))
                  : Column(
                      children: [
                        for (final m in list)
                          ListTile(
                            title: Text(m.groupName),
                            subtitle: !m.groupActive
                                ? const Text('Group disabled')
                                : null,
                            trailing: Wrap(
                              spacing: AppSpacing.xs,
                              children: [
                                if (m.isGroupAdmin)
                                  const StatusChip(
                                    'Group Admin',
                                    tone: ChipTone.accent,
                                  ),
                                if (!m.active)
                                  const StatusChip(
                                    'Disabled',
                                    tone: ChipTone.danger,
                                  ),
                              ],
                            ),
                            onTap: () =>
                                context.go(Routes.adminGroup(m.groupId)),
                          ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text('Manage', style: textTheme.labelLarge),
          const SizedBox(height: AppSpacing.sm),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Rename'),
                  onTap: () => _rename(context, ref),
                ),
                ListTile(
                  leading: const Icon(Icons.key_rounded),
                  title: const Text('Reset password'),
                  onTap: () => _resetPassword(context, ref),
                ),
                if (!isSelf) ...[
                  ListTile(
                    leading: Icon(
                      user.isActive
                          ? Icons.block_rounded
                          : Icons.check_circle_outline_rounded,
                      color: user.isActive ? AppColors.warning : null,
                    ),
                    title: Text(user.isActive ? 'Disable user' : 'Enable user'),
                    onTap: () => _toggleDisabled(context, ref),
                  ),
                  ListTile(
                    leading: const Icon(
                      Icons.delete_outline_rounded,
                      color: AppColors.expense,
                    ),
                    title: const Text(
                      'Delete user',
                      style: TextStyle(color: AppColors.expense),
                    ),
                    onTap: () => _delete(context, ref),
                  ),
                ],
              ],
            ),
          ),
          if (isSelf)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: Text(
                'You can\'t disable or delete your own account.',
                style: textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}
