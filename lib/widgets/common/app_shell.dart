import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/app_theme.dart';

class NavIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void setIndex(int index) => state = index;
}

final navIndexProvider =
    NotifierProvider<NavIndexNotifier, int>(NavIndexNotifier.new);

/// Root shell: keeps every tab alive and shows a floating glass nav bar.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.tabs});

  final List<AppTab> tabs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(navIndexProvider).clamp(0, tabs.length - 1);

    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          IndexedStack(
            index: index,
            children: [for (final t in tabs) t.page],
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 14 + MediaQuery.paddingOf(context).bottom,
            child: _FloatingNavBar(
              tabs: tabs,
              index: index,
              onChanged: (i) => ref.read(navIndexProvider.notifier).setIndex(i),
            ),
          ),
        ],
      ),
    );
  }
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
    final centerIdx = tabs.length ~/ 2;
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
                  isCenter: i == centerIdx,
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
    this.isCenter = false,
  });

  final AppTab tab;
  final bool selected;
  final VoidCallback onTap;
  final bool isCenter;

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
            scale: selected ? 1.12 : (isCenter ? 1.05 : 1.0),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutBack,
            child: isCenter
                ? Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppColors.primary.withValues(alpha: 0.15)
                          : Colors.transparent,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      selected ? tab.selectedIcon : tab.icon,
                      size: 22,
                      color: color,
                    ),
                  )
                : Icon(
                    selected ? tab.selectedIcon : tab.icon,
                    size: 21,
                    color: color,
                  ),
          ),
          const SizedBox(height: 3),
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
