import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'config/app_theme.dart';
import 'screens/home_screen.dart';
import 'services/storage_service.dart';
import 'widgets/common/app_shell.dart';

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

  // Low RAM optimization: restrict Flutter image cache to 80 images & 40 MB
  // to prevent Android Low Memory Killer (LMK) from killing the process.
  PaintingBinding.instance.imageCache.maximumSize = 80;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 40 * 1024 * 1024;
  WidgetsBinding.instance.addObserver(_MemoryPressureObserver());

  // Unlock high refresh rate (90Hz / 120Hz) on high refresh rate displays
  if (Platform.isAndroid) {
    try {
      await FlutterDisplayMode.setHighRefreshRate();
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
      home: const AppShell(
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
            page: _Placeholder('Movies'),
          ),
          AppTab(
            label: 'Series',
            icon: LucideIcons.tv,
            selectedIcon: LucideIcons.tv,
            page: _Placeholder('Series'),
          ),
          AppTab(
            label: 'Anime',
            icon: LucideIcons.sparkles,
            selectedIcon: LucideIcons.sparkles,
            page: _Placeholder('Anime'),
          ),
          AppTab(
            label: 'Watchlist',
            icon: LucideIcons.bookmark,
            selectedIcon: LucideIcons.bookmark,
            page: _Placeholder('Watchlist'),
          ),
        ],
      ),
    );
  }
}

/// Temporary tab body; replaced by real screens in the next steps.
class _Placeholder extends StatelessWidget {
  const _Placeholder(this.label);

  final String label;

  @override
  Widget build(BuildContext context) =>
      Center(child: Text(label, style: Theme.of(context).textTheme.titleLarge));
}
