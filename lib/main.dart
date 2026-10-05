import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'config/app_theme.dart';
import 'screens/home_screen.dart';
import 'services/storage_service.dart';
import 'widgets/common/app_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
