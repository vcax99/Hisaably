import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_spacing.dart';
import '../features/transactions/presentation/add_transaction_sheet.dart';

class ShellTab {
  const ShellTab({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Bottom-navigation shell: two tabs, a centre "+" button, two tabs.
/// There is no sidebar anywhere in the app.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell, required this.tabs})
    : assert(tabs.length == 4, 'Shell expects exactly 4 tabs around the +');

  final StatefulNavigationShell navigationShell;
  final List<ShellTab> tabs;

  void _onTab(int index) => navigationShell.goBranch(
    index,
    initialLocation: index == navigationShell.currentIndex,
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: AppSpacing.bottomNavHeight,
            child: Row(
              children: [
                for (var i = 0; i < 2; i++) _tabItem(i),
                const Expanded(child: Center(child: _AddButton())),
                for (var i = 2; i < 4; i++) _tabItem(i),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabItem(int index) {
    final tab = tabs[index];
    return Expanded(
      child: _NavItem(
        key: ValueKey('nav-${tab.label}'),
        tab: tab,
        selected: navigationShell.currentIndex == index,
        onTap: () => _onTab(index),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    super.key,
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final ShellTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textMuted;
    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        radius: 32,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              selected ? tab.selectedIcon : tab.icon,
              color: color,
              size: 24,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              tab.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: color,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Add transaction',
      excludeSemantics: true,
      child: Material(
        color: AppColors.accent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => showAddTransactionSheet(context),
          child: const SizedBox(
            width: 52,
            height: 52,
            child: Icon(Icons.add_rounded, color: AppColors.onAccent, size: 28),
          ),
        ),
      ),
    );
  }
}
