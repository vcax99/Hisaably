import 'package:flutter/material.dart';

import '../../../core/widgets/placeholder_screen.dart';
import '../../notifications/presentation/notification_bell.dart';
import '../../settings/presentation/account_button.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'Dashboard',
      icon: Icons.space_dashboard_outlined,
      message: 'Balance, monthly totals and charts will appear here.',
      actions: [NotificationBell(), AccountButton()],
    );
  }
}
