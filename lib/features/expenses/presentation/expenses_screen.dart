import 'package:flutter/material.dart';

import '../../../core/widgets/placeholder_screen.dart';

class ExpensesScreen extends StatelessWidget {
  const ExpensesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'Expenses',
      icon: Icons.receipt_long_outlined,
      message: 'Group expenses with filters will appear here.',
    );
  }
}
