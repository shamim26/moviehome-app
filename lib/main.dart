import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:media_kit/media_kit.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'config/app_theme.dart';
import 'screens/home_screen.dart';
import 'screens/movies_screen.dart';
import 'screens/search_screen.dart';
import 'screens/series_screen.dart';
import 'screens/watchlist_screen.dart';
import 'services/storage_service.dart';
import 'widgets/common/app_shell.dart';
import 'widgets/common/network_protection_guard.dart';

/// Observer that flushes image memory cache on OS low-memory warnings.
class _MemoryPressureObserver with WidgetsBindingObserver {
  @override
  void didHaveMemoryPressure() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // Low RAM optimization: restrict Flutter image cache to 80 images & 40 MB
  // to prevent Android Low Memory Killer (LMK) from killing the process.
  PaintingBinding.instance.imageCache.maximumSize = 80;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 40 * 1024 * 1024;
  WidgetsBinding.instance.addObserver(_MemoryPressureObserver());

  // Battery & thermal optimization: enforce standard 60Hz refresh rate
  // to avoid battery drain and overheating at 120Hz.
  if (Platform.isAndroid) {
    try {
      await FlutterDisplayMode.setLowRefreshRate();
    } catch (_) {}
  }

  final prefs = await SharedPreferences.getInstance();

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const MovieHomeApp(),
    ),
  );
}

class MovieHomeApp extends StatelessWidget {
  const MovieHomeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Movie Home',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const NetworkProtectionGuard(
        child: AppShell(
          tabs: [
            AppTab(
              label: 'Home',
              icon: LucideIcons.house,
              selectedIcon: LucideIcons.house,
              page: HomeScreen(),
            ),
            AppTab(
              label: 'Movies',
              icon: LucideIcons.clapperboard,
              selectedIcon: LucideIcons.clapperboard,
              page: MoviesScreen(),
            ),
            AppTab(
              label: 'Search',
              icon: LucideIcons.search,
              selectedIcon: LucideIcons.search,
              page: SearchScreen(isTab: true),
            ),
            AppTab(
              label: 'Series',
              icon: LucideIcons.tv,
              selectedIcon: LucideIcons.tv,
              page: SeriesScreen(),
            ),
            AppTab(
              label: 'Watchlist',
              icon: LucideIcons.bookmark,
              selectedIcon: LucideIcons.bookmark,
              page: WatchlistScreen(),
            ),
          ],
        ),
      ),
    );
  }
}
