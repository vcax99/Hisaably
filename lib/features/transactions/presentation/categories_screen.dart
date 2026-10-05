import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/async_value_view.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/status_chip.dart';
import '../application/transactions_providers.dart';
import '../data/transactions_repository.dart';
import '../domain/transaction.dart';

/// Group Admin / Super Admin: rename or delete a group's categories
/// (decision 8). New categories come from "Other" in the transaction form.
class CategoriesScreen extends ConsumerWidget {
  const CategoriesScreen({super.key, required this.groupId});

  final String groupId;

  void _refresh(WidgetRef ref) {
    ref.invalidate(allCategoriesProvider(groupId));
    for (final type in TransactionType.values) {
      ref.invalidate(categoriesProvider((groupId: groupId, type: type)));
    }
  }

  Future<void> _rename(BuildContext context, WidgetRef ref, Category c) async {
    final name = await showTextInputDialog(
      context,
      title: 'Rename category',
      label: 'Name',
      confirmLabel: 'Save',
      initialValue: c.name,
      validator: (v) => v.length > 40 ? 'At most 40 characters' : null,
    );
    if (name == null || name == c.name || !context.mounted) return;
    final ok = await runAction(
      context,
      () => ref.read(categoriesRepositoryProvider).rename(c.id, name),
      successMessage: 'Renamed. Past transactions were updated too.',
    );
    if (ok) {
      _refresh(ref);
      invalidateTransactions(ref);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Category c) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete "${c.name}"?',
      message:
          'It won\'t be offered for new transactions. Past transactions keep '
          'the name "${c.name}".',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    final ok = await runAction(
      context,
      () => ref.read(categoriesRepositoryProvider).delete(c.id),
      successMessage: 'Category deleted',
    );
    if (ok) _refresh(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(allCategoriesProvider(groupId));
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Categories')),
      body: AsyncValueView(
        value: categories,
        onRetry: () => ref.invalidate(allCategoriesProvider(groupId)),
        data: (list) => ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            Text(
              'New categories are added by choosing "Other" when recording a '
              'transaction.',
              style: textTheme.bodySmall,
            ),
            for (final type in TransactionType.values) ...[
              const SizedBox(height: AppSpacing.xl),
              Text(
                type == TransactionType.expense ? 'Expense' : 'Income',
                style: textTheme.labelLarge,
              ),
              const SizedBox(height: AppSpacing.sm),
              Card(
                child: Column(
                  children: [
                    for (final c in list.where((c) => c.type == type))
                      ListTile(
                        minTileHeight: 56,
                        title: Text(
                          c.name,
                          style: TextStyle(
                            color: c.isActive
                                ? AppColors.textPrimary
                                : AppColors.textMuted,
                          ),
                        ),
                        trailing: c.isActive
                            ? PopupMenuButton<String>(
                                tooltip: 'Category actions',
                                color: AppColors.elevated,
                                onSelected: (action) => action == 'rename'
                                    ? _rename(context, ref, c)
                                    : _delete(context, ref, c),
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'rename',
                                    child: Text('Rename'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text(
                                      'Delete',
                                      style: TextStyle(
                                        color: AppColors.expense,
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : const StatusChip('Deleted'),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
