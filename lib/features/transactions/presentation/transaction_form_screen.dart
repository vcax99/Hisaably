import 'package:flutter/material.dart';

import '../../../core/widgets/placeholder_screen.dart';

class TransactionFormScreen extends StatelessWidget {
  const TransactionFormScreen({super.key, required this.isExpense});

  final bool isExpense;

  @override
  Widget build(BuildContext context) {
    return PlaceholderScreen(
      title: isExpense ? 'Add Expense' : 'Add Income',
      icon: isExpense
          ? Icons.arrow_upward_rounded
          : Icons.arrow_downward_rounded,
      message: 'The transaction form arrives in Phase 7.',
    );
  }
}
