import 'package:flutter/material.dart';

import '../../notifications/presentation/notification_bell.dart';
import '../../transactions/domain/transaction.dart';
import '../../transactions/presentation/transactions_view.dart';

/// Member shell → Expenses tab.
class ExpensesScreen extends StatelessWidget {
  const ExpensesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Expenses'),
        actions: const [NotificationBell()],
      ),
      body: const TransactionsView(type: TransactionType.expense),
    );
  }
}
