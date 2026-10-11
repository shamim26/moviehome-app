import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../config/app_theme.dart';
import '../models/media_item.dart';
import '../providers/watchlist_provider.dart';
import '../services/storage_service.dart';
import '../widgets/common/app_shell.dart';
import '../widgets/common/media_card.dart';
import 'detail_screen.dart';

enum WatchlistFilter { all, movies, series, inProgress }

enum WatchlistSort { recentlyAdded, highestRated, title }

class WatchlistScreen extends ConsumerStatefulWidget {
  const WatchlistScreen({super.key});

  @override
  ConsumerState<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends ConsumerState<WatchlistScreen> {
  WatchlistFilter _currentFilter = WatchlistFilter.all;
  WatchlistSort _currentSort = WatchlistSort.recentlyAdded;

  @override
  Widget build(BuildContext context) {
    final watchlist = ref.watch(watchlistProvider);
    final storage = ref.watch(storageServiceProvider);

    // Compute KPI metrics
    final totalCount = watchlist.length;
    final movieCount = watchlist.where((m) => m.mediaType == MediaType.movie).length;
    final seriesCount = watchlist.where((m) => m.mediaType == MediaType.tv).length;

    final inProgressItems = watchlist.where((m) {
      final prog = storage.getWatchProgress(m.id, m.mediaType);
      return prog != null;
    }).toList();
    final inProgressCount = inProgressItems.length;

    final avgRating = watchlist.isEmpty
        ? 0.0
        : watchlist
                .map((m) => m.voteAverage)
                .where((v) => v > 0)
                .fold<double>(0.0, (acc, v) => acc + v) /
            (watchlist.where((m) => m.voteAverage > 0).isEmpty
                ? 1
                : watchlist.where((m) => m.voteAverage > 0).length);

    // Filter list
    List<MediaItem> displayed = switch (_currentFilter) {
      WatchlistFilter.all => watchlist,
      WatchlistFilter.movies =>
        watchlist.where((m) => m.mediaType == MediaType.movie).toList(),
      WatchlistFilter.series =>
        watchlist.where((m) => m.mediaType == MediaType.tv).toList(),
      WatchlistFilter.inProgress => inProgressItems,
    };

    // Sort list
    displayed = switch (_currentSort) {
      WatchlistSort.recentlyAdded => List.of(displayed),
      WatchlistSort.highestRated =>
        List.of(displayed)..sort((a, b) => b.voteAverage.compareTo(a.voteAverage)),
      WatchlistSort.title =>
        List.of(displayed)..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase())),
    };

    final bottomInset = 110 + MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            // Top Header
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Watchlist',
                            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                              color: AppColors.foreground,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'Track your saved movies & series',
                            style: TextStyle(
                              color: AppColors.mutedForeground,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (watchlist.isNotEmpty)
                      PopupMenuButton<WatchlistSort>(
                        icon: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppColors.card,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: const Icon(
                            LucideIcons.arrowUpDown,
                            size: 16,
                            color: AppColors.foreground,
                          ),
                        ),
                        color: AppColors.card,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: const BorderSide(color: AppColors.border),
                        ),
                        onSelected: (sort) => setState(() => _currentSort = sort),
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: WatchlistSort.recentlyAdded,
                            child: Text('Recently Added'),
                          ),
                          const PopupMenuItem(
                            value: WatchlistSort.highestRated,
                            child: Text('Highest Rated'),
                          ),
                          const PopupMenuItem(
                            value: WatchlistSort.title,
                            child: Text('Title (A-Z)'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),

            // KPI Dashboard Card
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: _KpiStatsCard(
                  total: totalCount,
                  movies: movieCount,
                  series: seriesCount,
                  inProgress: inProgressCount,
                  avgRating: avgRating,
                ),
              ),
            ),

            // Filter Tabs
            if (watchlist.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _FilterChip(
                          label: 'All ($totalCount)',
                          selected: _currentFilter == WatchlistFilter.all,
                          onTap: () => setState(() => _currentFilter = WatchlistFilter.all),
                        ),
                        const SizedBox(width: 8),
                        _FilterChip(
                          label: 'Movies ($movieCount)',
                          selected: _currentFilter == WatchlistFilter.movies,
                          onTap: () => setState(() => _currentFilter = WatchlistFilter.movies),
                        ),
                        const SizedBox(width: 8),
                        _FilterChip(
                          label: 'Series ($seriesCount)',
                          selected: _currentFilter == WatchlistFilter.series,
                          onTap: () => setState(() => _currentFilter = WatchlistFilter.series),
                        ),
                        const SizedBox(width: 8),
                        _FilterChip(
                          label: 'In Progress ($inProgressCount)',
                          selected: _currentFilter == WatchlistFilter.inProgress,
                          onTap: () => setState(() => _currentFilter = WatchlistFilter.inProgress),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Content Grid or Empty State
            if (watchlist.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyWatchlistView(
                  onExplore: () => ref.read(navIndexProvider.notifier).setIndex(1),
                ),
              )
            else if (displayed.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          LucideIcons.filterX,
                          size: 40,
                          color: AppColors.mutedForeground,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'No titles in this filter',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppColors.foreground,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () => setState(() => _currentFilter = WatchlistFilter.all),
                          child: const Text('Reset Filter'),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, bottomInset),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 16,
                    childAspectRatio: 0.54,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final item = displayed[index];
                      final heroTag = MediaCard.heroTag('watchlist', item);
                      final progress = storage.getWatchProgress(item.id, item.mediaType);

                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          MediaCard(
                            item: item,
                            heroPrefix: 'watchlist',
                            onTap: () => DetailScreen.push(context, item, heroTag),
                          ),
                          // Delete from watchlist button
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(16),
                                onTap: () async {
                                  await ref.read(watchlistProvider.notifier).toggle(item);
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Removed "${item.title}"'),
                                      duration: const Duration(seconds: 3),
                                      action: SnackBarAction(
                                        label: 'Undo',
                                        textColor: AppColors.primary,
                                        onPressed: () {
                                          ref.read(watchlistProvider.notifier).toggle(item);
                                        },
                                      ),
                                    ),
                                  );
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.7),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white.withValues(alpha: 0.2),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: const Icon(
                                    LucideIcons.x,
                                    size: 13,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // Watching indicator badge
                          if (progress != null)
                            Positioned(
                              bottom: 48,
                              left: 6,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.primary.withValues(alpha: 0.9),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  item.mediaType == MediaType.tv
                                      ? 'S${progress['season']} E${progress['episode']}'
                                      : 'Resume',
                                  style: const TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                    childCount: displayed.length,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The KPI metrics card showing statistics of the user's saved library.
class _KpiStatsCard extends StatelessWidget {
  const _KpiStatsCard({
    required this.total,
    required this.movies,
    required this.series,
    required this.inProgress,
    required this.avgRating,
  });

  final int total;
  final int movies;
  final int series;
  final int inProgress;
  final double avgRating;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF1B202E),
            const Color(0xFF141722),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row with badge
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      LucideIcons.barChart2,
                      size: 16,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Library Overview',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                      color: AppColors.foreground,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: Text(
                  '$total Titles',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // KPI Stats Row
          Row(
            children: [
              Expanded(
                child: _KpiMetricItem(
                  label: 'Movies',
                  value: '$movies',
                  icon: LucideIcons.clapperboard,
                  accentColor: const Color(0xFF38BDF8),
                ),
              ),
              Container(
                height: 38,
                width: 1,
                color: Colors.white.withValues(alpha: 0.08),
              ),
              Expanded(
                child: _KpiMetricItem(
                  label: 'Series',
                  value: '$series',
                  icon: LucideIcons.tv,
                  accentColor: const Color(0xFFA855F7),
                ),
              ),
              Container(
                height: 38,
                width: 1,
                color: Colors.white.withValues(alpha: 0.08),
              ),
              Expanded(
                child: _KpiMetricItem(
                  label: 'Watching',
                  value: '$inProgress',
                  icon: LucideIcons.playCircle,
                  accentColor: const Color(0xFF22C55E),
                ),
              ),
              Container(
                height: 38,
                width: 1,
                color: Colors.white.withValues(alpha: 0.08),
              ),
              Expanded(
                child: _KpiMetricItem(
                  label: 'Avg Score',
                  value: avgRating > 0 ? avgRating.toStringAsFixed(1) : '-',
                  icon: LucideIcons.star,
                  accentColor: const Color(0xFFEAB308),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _KpiMetricItem extends StatelessWidget {
  const _KpiMetricItem({
    required this.label,
    required this.value,
    required this.icon,
    required this.accentColor,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 13, color: accentColor),
            const SizedBox(width: 4),
            Text(
              value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: AppColors.foreground,
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w500,
            color: AppColors.mutedForeground,
          ),
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? Colors.white : AppColors.mutedForeground,
          ),
        ),
      ),
    );
  }
}

class _EmptyWatchlistView extends StatelessWidget {
  const _EmptyWatchlistView({required this.onExplore});

  final VoidCallback onExplore;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: AppColors.card,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.border),
              ),
              child: const Icon(
                LucideIcons.bookmarkPlus,
                size: 42,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Your Watchlist is Empty',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: AppColors.foreground,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Save movies and TV series to keep track of what you want to watch next.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.mutedForeground,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onExplore,
              icon: const Icon(LucideIcons.compass, size: 16),
              label: const Text('Explore Movies'),
            ),
          ],
        ),
      ),
    );
  }
}
