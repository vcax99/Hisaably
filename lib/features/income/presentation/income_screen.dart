import 'package:flutter/material.dart';

import '../../notifications/presentation/notification_bell.dart';
import '../../transactions/domain/transaction.dart';
import '../../transactions/presentation/transactions_view.dart';

/// Member shell → Income tab.
class IncomeScreen extends StatelessWidget {
  const IncomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Income'),
        actions: const [NotificationBell()],
      ),
      body: const TransactionsView(type: TransactionType.income),
    );
  }
}
