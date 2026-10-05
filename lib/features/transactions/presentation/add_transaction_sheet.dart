import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../routing/routes.dart';

/// Bottom sheet opened by the centre "+" button: Add Expense / Add Income.
Future<void> showAddTransactionSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    builder: (sheetContext) {
      void open(String type) {
        Navigator.of(sheetContext).pop();
        context.push(Routes.addTransaction(type));
      }

      // Keep the last option clear of the gesture bar / home indicator.
      final bottomInset = MediaQuery.viewPaddingOf(sheetContext).bottom;
      return Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.lg + bottomInset,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Option(
              icon: Icons.arrow_upward_rounded,
              color: AppColors.expense,
              title: 'Add Expense',
              subtitle: 'Money spent from the group',
              onTap: () => open('expense'),
            ),
            const SizedBox(height: AppSpacing.sm),
            _Option(
              icon: Icons.arrow_downward_rounded,
              color: AppColors.income,
              title: 'Add Income',
              subtitle: 'Money received by the group',
              onTap: () => open('income'),
            ),
          ],
        ),
      );
    },
  );
}

class _Option extends StatelessWidget {
  const _Option({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.elevated,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: ListTile(
        minTileHeight: 64,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        ),
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          child: Icon(icon, color: color),
        ),
        title: Text(title, style: Theme.of(context).textTheme.titleMedium),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right, color: AppColors.textMuted),
        onTap: onTap,
      ),
    );
  }
}
