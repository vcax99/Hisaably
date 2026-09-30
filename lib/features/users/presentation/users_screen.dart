import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/async_value_view.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/status_chip.dart';
import '../../../routing/routes.dart';
import '../application/users_providers.dart';
import '../domain/app_user.dart';

/// Super Admin → Users tab: all users, searchable.
class UsersScreen extends ConsumerStatefulWidget {
  const UsersScreen({super.key});

  @override
  ConsumerState<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends ConsumerState<UsersScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(usersListProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Users'),
        actions: [
          IconButton(
            tooltip: 'New user',
            icon: const Icon(Icons.person_add_alt_1_rounded),
            onPressed: () => context.push(Routes.adminNewUser),
          ),
        ],
      ),
      body: AsyncValueView(
        value: users,
        onRetry: () => ref.invalidate(usersListProvider),
        data: (list) {
          final filtered = list.where((u) => u.matches(_query)).toList();
          return RefreshIndicator(
            onRefresh: () => ref.refresh(usersListProvider.future),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.xl,
              ),
              children: [
                TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search by name or username',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '${list.length} users · '
                  '${list.where((u) => !u.isActive).length} disabled',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.md),
                if (filtered.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: AppSpacing.xxl),
                    child: EmptyState(
                      icon: Icons.person_search_rounded,
                      title: 'No users found',
                    ),
                  )
                else
                  Card(
                    child: Column(
                      children: [
                        for (final (i, user) in filtered.indexed) ...[
                          if (i > 0) const Divider(indent: 72),
                          UserTile(
                            user: user,
                            onTap: () =>
                                context.push(Routes.adminUser(user.id)),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class UserTile extends StatelessWidget {
  const UserTile({super.key, required this.user, this.onTap, this.trailing});

  final AppUser user;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minTileHeight: 64,
      onTap: onTap,
      leading: UserAvatar(name: user.name, dimmed: !user.isActive),
      title: Text(
        user.name,
        style: TextStyle(
          color: user.isActive ? AppColors.textPrimary : AppColors.textMuted,
        ),
      ),
      subtitle: Text('@${user.username}'),
      trailing:
          trailing ??
          Wrap(
            spacing: AppSpacing.xs,
            children: [
              if (user.isSuperAdmin)
                const StatusChip('Super Admin', tone: ChipTone.accent),
              if (!user.isActive)
                const StatusChip('Disabled', tone: ChipTone.danger),
            ],
          ),
    );
  }
}

class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, required this.name, this.dimmed = false});

  final String name;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 20,
      backgroundColor: AppColors.elevated,
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: dimmed ? AppColors.textMuted : AppColors.textPrimary,
        ),
      ),
    );
  }
}
