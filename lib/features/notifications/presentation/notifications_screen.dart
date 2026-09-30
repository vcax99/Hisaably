import 'package:flutter/material.dart';

import '../../../core/widgets/placeholder_screen.dart';

class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'Notifications',
      icon: Icons.notifications_none_rounded,
      message: 'Transaction and monthly notifications will appear here.',
    );
  }
}
