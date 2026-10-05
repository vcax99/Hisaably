import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../groups/application/groups_providers.dart';
import 'transactions_view.dart';

/// One group's ledger (income + expense). Reached from the group screen;
/// it's where the Super Admin (no Expense/Income tabs) reviews and edits.
class GroupTransactionsScreen extends ConsumerWidget {
  const GroupTransactionsScreen({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(groupProvider(groupId)).value?.name;
    return Scaffold(
      appBar: AppBar(
        title: Text(name == null ? 'Transactions' : '$name · Ledger'),
      ),
      body: TransactionsView(fixedGroupId: groupId),
    );
  }
}
