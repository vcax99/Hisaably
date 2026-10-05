import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/errors/error_mapper.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/ist_date.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/async_value_view.dart';
import '../../../core/widgets/empty_state.dart';
import '../../groups/domain/group.dart';
import '../application/transactions_providers.dart';
import '../data/transactions_repository.dart';
import '../domain/transaction.dart';

/// Add Expense / Add Income, or edit an existing transaction ([existing]).
class TransactionFormScreen extends ConsumerWidget {
  const TransactionFormScreen({
    super.key,
    required this.type,
    this.existing,
    this.initialGroupId,
  });

  final TransactionType type;
  final Transaction? existing;
  final String? initialGroupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editing = existing != null;
    final title = editing
        ? 'Edit ${type.label.toLowerCase()}'
        : 'Add ${type.label}';
    final groups = ref.watch(transactionGroupsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: AsyncValueView(
        value: groups,
        onRetry: () => ref.invalidate(transactionGroupsProvider),
        data: (list) {
          if (list.isEmpty && !editing) {
            return const EmptyState(
              icon: Icons.groups_outlined,
              title: 'You are not in any group yet',
              message:
                  'Transactions belong to a group. Ask your administrator '
                  'to add you to one.',
            );
          }
          return _TransactionForm(
            type: existing?.type ?? type,
            existing: existing,
            groups: list,
            initialGroupId: initialGroupId,
          );
        },
      ),
    );
  }
}

class _TransactionForm extends ConsumerStatefulWidget {
  const _TransactionForm({
    required this.type,
    required this.existing,
    required this.groups,
    required this.initialGroupId,
  });

  final TransactionType type;
  final Transaction? existing;
  final List<Group> groups;
  final String? initialGroupId;

  @override
  ConsumerState<_TransactionForm> createState() => _TransactionFormState();
}

class _TransactionFormState extends ConsumerState<_TransactionForm> {
  static const _other = '\u0000other';

  final _formKey = GlobalKey<FormState>();
  late final _amount = TextEditingController(
    text: widget.existing == null
        ? ''
        : Money.toNumericString(widget.existing!.amountPaise)
              .replaceFirst(RegExp(r'\.00$'), ''),
  );
  late final _description = TextEditingController(
    text: widget.existing?.description ?? '',
  );
  final _otherName = TextEditingController();

  late String? _groupId = _initialGroup();
  late String? _category = widget.existing?.category;
  late DateTime _date = widget.existing?.date ?? IstDate.today();
  bool _busy = false;
  bool _submitted = false;
  String? _error;

  bool get _editing => widget.existing != null;
  bool get _isExpense => widget.type == TransactionType.expense;

  String? _initialGroup() {
    if (widget.existing != null) return widget.existing!.groupId;
    final ids = widget.groups.map((g) => g.id).toSet();
    for (final candidate in [
      widget.initialGroupId,
      ref.read(lastUsedGroupProvider),
    ]) {
      if (candidate != null && ids.contains(candidate)) return candidate;
    }
    return widget.groups.length == 1 ? widget.groups.single.id : null;
  }

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    _otherName.dispose();
    super.dispose();
  }

  String? get _resolvedCategory {
    if (_category == _other) {
      final name = _otherName.text.trim().replaceAll(RegExp(r'\s+'), ' ');
      return name.isEmpty ? null : name;
    }
    return _category;
  }

  Future<void> _pickDate() async {
    final today = IstDate.today();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(_date.year, _date.month, _date.day),
      firstDate: DateTime(2000),
      // Decision 6: no future-dated transactions (IST).
      lastDate: DateTime(today.year, today.month, today.day),
      helpText: 'Transaction date',
    );
    if (picked != null) {
      setState(
        () => _date = DateTime.utc(picked.year, picked.month, picked.day),
      );
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    if (!_submitted) setState(() => _submitted = true);
    final valid = _formKey.currentState!.validate();
    final categoryMissing = _isExpense && _resolvedCategory == null;
    if (!valid || _groupId == null || categoryMissing) {
      setState(
        () => _error = _groupId == null
            ? 'Choose a group.'
            : categoryMissing
            ? 'Choose a category for the expense.'
            : null,
      );
      return;
    }
    if (IstDate.isFuture(_date)) {
      setState(() => _error = 'Transaction date cannot be in the future.');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final description = _description.text.trim();
    final draft = TransactionDraft(
      groupId: _groupId!,
      type: widget.type,
      amountPaise: Money.parseToPaise(_amount.text)!,
      category: _resolvedCategory,
      description: description.isEmpty ? null : description,
      date: _date,
    );
    try {
      final repo = ref.read(transactionsRepositoryProvider);
      var savedOffline = false;
      if (_editing) {
        await repo.update(
          widget.existing!.id,
          draft,
          expectedVersion: widget.existing!.syncVersion,
        );
      } else {
        final saved = await repo.add(draft);
        savedOffline = !saved.isSynced;
        ref.read(lastUsedGroupProvider.notifier).set(_groupId!);
      }
      invalidateTransactions(ref);
      if (_category == _other) {
        ref.invalidate(
          categoriesProvider((groupId: _groupId!, type: widget.type)),
        );
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      context.pop(true);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            _editing
                ? 'Changes saved'
                : savedOffline
                ? '${widget.type.label} saved offline · will sync when online'
                : '${widget.type.label} of ${Money.format(draft.amountPaise)} added',
          ),
        ),
      );
    } catch (e, st) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = mapError(e, st).message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final accent = _isExpense ? AppColors.expense : AppColors.income;

    return Form(
      key: _formKey,
      autovalidateMode: _submitted
          ? AutovalidateMode.onUserInteraction
          : AutovalidateMode.disabled,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          // Amount
          TextFormField(
            controller: _amount,
            enabled: !_busy,
            autofocus: !_editing,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(
                RegExp(r'^\d{0,10}(\.\d{0,2})?'),
              ),
            ],
            style: textTheme.displaySmall?.copyWith(color: accent),
            decoration: InputDecoration(
              labelText: 'Amount',
              prefixText: '₹ ',
              prefixStyle: textTheme.displaySmall?.copyWith(color: accent),
            ),
            validator: (v) {
              final paise = Money.parseToPaise(v ?? '');
              if (paise == null) return 'Enter an amount';
              if (paise <= 0) return 'Amount must be more than ₹0';
              return null;
            },
          ),
          const SizedBox(height: AppSpacing.lg),

          // Group
          if (_editing)
            _ReadOnlyRow(
              icon: Icons.groups_outlined,
              label: 'Group',
              value:
                  widget.groups
                      .where((g) => g.id == _groupId)
                      .map((g) => g.name)
                      .firstOrNull ??
                  'Group',
            )
          else if (widget.groups.length == 1)
            _ReadOnlyRow(
              icon: Icons.groups_outlined,
              label: 'Group',
              value: widget.groups.single.name,
            )
          else
            DropdownButtonFormField<String>(
              initialValue: _groupId,
              isExpanded: true,
              dropdownColor: AppColors.elevated,
              decoration: const InputDecoration(labelText: 'Group'),
              items: [
                for (final g in widget.groups)
                  DropdownMenuItem(value: g.id, child: Text(g.name)),
              ],
              onChanged: _busy
                  ? null
                  : (id) => setState(() {
                      _groupId = id;
                      _category = null; // categories are per group
                    }),
              validator: (v) => v == null ? 'Choose a group' : null,
            ),
          const SizedBox(height: AppSpacing.xl),

          // Category
          Text(
            _isExpense ? 'Category' : 'Category (optional)',
            style: textTheme.labelLarge,
          ),
          const SizedBox(height: AppSpacing.sm),
          if (_groupId == null)
            Text('Choose a group first', style: textTheme.bodySmall)
          else
            _CategoryPicker(
              groupId: _groupId!,
              type: widget.type,
              selected: _category,
              otherValue: _other,
              enabled: !_busy,
              onSelected: (c) => setState(() => _category = c),
            ),
          if (_category == _other) ...[
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: _otherName,
              enabled: !_busy,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              maxLength: 40,
              decoration: const InputDecoration(
                labelText: 'New category name',
                helperText: 'Added to this group\'s categories',
              ),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Enter a category name' : null,
            ),
          ],
          const SizedBox(height: AppSpacing.xl),

          // Description
          TextFormField(
            controller: _description,
            enabled: !_busy,
            maxLength: 500,
            minLines: 1,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
              counterText: '',
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // Date
          Card(
            child: ListTile(
              minTileHeight: 56,
              leading: const Icon(Icons.calendar_today_outlined),
              title: const Text('Date'),
              subtitle: Text(_dateLabel(_date)),
              trailing: const Icon(Icons.chevron_right),
              onTap: _busy ? null : _pickDate,
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: AppSpacing.lg),
            Text(_error!, style: const TextStyle(color: AppColors.expense)),
          ],
          const SizedBox(height: AppSpacing.xl),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: _busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    _editing
                        ? 'Save changes'
                        : 'Save ${type.label.toLowerCase()}',
                  ),
          ),
        ],
      ),
    );
  }

  TransactionType get type => widget.type;
}

String _dateLabel(DateTime date) {
  final today = IstDate.today();
  final d = IstDate.dateOnly(date);
  if (d == today) return 'Today';
  if (d == today.subtract(const Duration(days: 1))) return 'Yesterday';
  return DateFormat('EEE, d MMM yyyy').format(d);
}

class _ReadOnlyRow extends StatelessWidget {
  const _ReadOnlyRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        minTileHeight: 56,
        leading: Icon(icon),
        title: Text(label),
        subtitle: Text(value),
      ),
    );
  }
}

class _CategoryPicker extends ConsumerWidget {
  const _CategoryPicker({
    required this.groupId,
    required this.type,
    required this.selected,
    required this.otherValue,
    required this.enabled,
    required this.onSelected,
  });

  final String groupId;
  final TransactionType type;
  final String? selected;
  final String otherValue;
  final bool enabled;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (groupId: groupId, type: type);
    final categories = ref.watch(categoriesProvider(key));
    // Offline before this group's categories were ever loaded: still allow
    // saving with "Other" + a name (created server-side on sync).
    final offlineNoCache =
        categories.hasError &&
        !categories.hasValue &&
        mapError(categories.error!) is NetworkFailure;
    return AsyncValueView(
      value: offlineNoCache
          ? const AsyncValue<List<Category>>.data([])
          : categories,
      onRetry: () => ref.invalidate(categoriesProvider(key)),
      data: (list) {
        final names = [for (final c in list) c.name];
        // Keep a (deleted or renamed-away) category of an edited transaction.
        if (selected != null &&
            selected != otherValue &&
            !names.any((n) => n.toLowerCase() == selected!.toLowerCase())) {
          names.add(selected!);
        }
        final chips = Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final name in names)
              ChoiceChip(
                label: Text(name),
                selected: selected?.toLowerCase() == name.toLowerCase(),
                onSelected: enabled
                    ? (on) => onSelected(
                        on || type == TransactionType.expense ? name : null,
                      )
                    : null,
              ),
            ChoiceChip(
              avatar: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Other'),
              selected: selected == otherValue,
              onSelected: enabled ? (_) => onSelected(otherValue) : null,
            ),
          ],
        );
        if (!offlineNoCache) return chips;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Offline: this group\'s categories haven\'t loaded yet. '
              'Choose Other and type the category name.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            chips,
          ],
        );
      },
    );
  }
}
