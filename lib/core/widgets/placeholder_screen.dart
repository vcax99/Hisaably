import 'package:flutter/material.dart';

import 'empty_state.dart';

/// Temporary screen body for tabs whose feature phase hasn't landed yet.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({
    super.key,
    required this.title,
    required this.icon,
    required this.message,
    this.actions,
  });

  final String title;
  final IconData icon;
  final String message;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: EmptyState(icon: icon, title: title, message: message),
    );
  }
}
