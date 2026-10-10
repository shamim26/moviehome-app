import 'package:flutter/material.dart';

import '../../config/app_theme.dart';

/// Root shell: keeps every tab alive and shows a floating glass nav bar.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.tabs});

  final List<AppTab> tabs;

  @override
  State<AppShell> createState() => _AppShellState();
}

class AppTab {
  const AppTab({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.page,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget page;
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          IndexedStack(
            index: _index,
            children: [for (final t in widget.tabs) t.page],
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 14 + MediaQuery.paddingOf(context).bottom,
            child: _FloatingNavBar(
              tabs: widget.tabs,
              index: _index,
              onChanged: (i) => setState(() => _index = i),
            ),
          ),
        ],
      ),
    );
  }
}

class _FloatingNavBar extends StatelessWidget {
  const _FloatingNavBar({
    required this.tabs,
    required this.index,
    required this.onChanged,
  });

  final List<AppTab> tabs;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: const Color(0xF412141A),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            for (var i = 0; i < tabs.length; i++)
              Expanded(
                child: _NavItem(
                  tab: tabs[i],
                  selected: i == index,
                  onTap: () => onChanged(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final AppTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.primary : AppColors.mutedForeground;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedScale(
            scale: selected ? 1.08 : 1,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutBack,
            child: Icon(
              selected ? tab.selectedIcon : tab.icon,
              size: 22,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: color,
            ),
            child: Text(tab.label),
          ),
        ],
      ),
    );
  }
}
