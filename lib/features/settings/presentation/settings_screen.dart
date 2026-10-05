import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_version.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/push/push_bootstrap.dart';
import '../../../core/sync/sync_bootstrap.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/user_context.dart';

/// Account details + sign out. Reached from the account icon on the
/// Dashboard (all roles) and from More (Super Admin).
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final unsynced = await unsyncedCount(ref);
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.elevated,
        title: const Text('Sign out?'),
        content: Text(
          unsynced > 0
              ? '$unsynced ${unsynced == 1 ? 'entry has' : 'entries have'} '
                    'not synced yet and will be lost if you sign out now. '
                    'Connect to the internet and sync first to keep '
                    '${unsynced == 1 ? 'it' : 'them'}.'
              : 'You will need your username and password to sign in again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.expense),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      // Clear first: once signed out this screen (and its ref) is gone.
      await unregisterPush(ref); // still authenticated here
      await clearLocalData(ref);
      await ref.read(sessionControllerProvider.notifier).signOut();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userContext = ref.watch(currentUserContextProvider);
    final textTheme = Theme.of(context).textTheme;
    final profile = userContext?.profile;

    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          if (profile != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: AppColors.elevated,
                      child: Text(
                        profile.name.characters.first.toUpperCase(),
                        style: textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(profile.name, style: textTheme.titleMedium),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            '@${profile.username}',
                            style: textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    if (profile.isSuperAdmin)
                      const _RoleChip(label: 'Super Admin'),
                  ],
                ),
              ),
            ),
          if (userContext != null &&
              userContext.activeMemberships.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            Text('Groups', style: textTheme.labelLarge),
            const SizedBox(height: AppSpacing.sm),
            Card(
              child: Column(
                children: [
                  for (final m in userContext.activeMemberships)
                    ListTile(
                      title: Text(m.groupName),
                      trailing: m.groupRole == GroupRole.groupAdmin
                          ? const _RoleChip(label: 'Group Admin')
                          : null,
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          OutlinedButton.icon(
            onPressed: () => _confirmSignOut(context, ref),
            icon: const Icon(Icons.logout_rounded, color: AppColors.expense),
            label: const Text('Sign out'),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text(
            [
              AppConstants.appName,
              ?ref.watch(appVersionProvider).value,
              'by ${AppConstants.author}',
            ].join(' · '),
            style: textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.accent,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
