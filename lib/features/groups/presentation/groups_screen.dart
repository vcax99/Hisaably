import 'package:flutter/material.dart';

import '../../../core/widgets/placeholder_screen.dart';

class GroupsScreen extends StatelessWidget {
  const GroupsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'Groups',
      icon: Icons.groups_outlined,
      message: 'Your groups and members will appear here.',
    );
  }
}
