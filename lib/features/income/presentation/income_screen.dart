import 'package:flutter/material.dart';

import '../../../core/widgets/placeholder_screen.dart';

class IncomeScreen extends StatelessWidget {
  const IncomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'Income',
      icon: Icons.savings_outlined,
      message: 'Group income with filters will appear here.',
    );
  }
}
