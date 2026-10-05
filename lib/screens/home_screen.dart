import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_theme.dart';
import '../models/media_item.dart';
import '../providers/home_provider.dart';
import '../widgets/common/hero_carousel.dart';
import '../widgets/common/media_row.dart';
import '../widgets/common/shimmer_box.dart';
import 'detail_screen.dart';
import 'player_screen.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  void _open(BuildContext context, MediaItem item, [String? heroTag]) {
    DetailScreen.push(context, item, heroTag);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trending = ref.watch(trendingProvider);

    Widget row(String title, FutureProvider<List<MediaItem>> provider) {
      final async = ref.watch(provider);
      return AsyncMediaRow(
        title: title,
        isLoading: async.isLoading && !async.hasValue,
        error: async.hasError && !async.hasValue ? async.error : null,
        items: async.value ?? const [],
        onItemTap: (m, tag) => _open(context, m, tag),
        onRetry: () => ref.invalidate(provider),
      );
    }

    return RefreshIndicator(
      color: AppColors.primary,
      backgroundColor: AppColors.card,
      edgeOffset: MediaQuery.paddingOf(context).top,
      onRefresh: () async {
        ref.invalidate(trendingProvider);
        ref.invalidate(popularMoviesProvider);
        ref.invalidate(topRatedMoviesProvider);
        ref.invalidate(nowPlayingMoviesProvider);
        ref.invalidate(popularTvProvider);
        ref.invalidate(topRatedTvProvider);
        try {
          final _ = await ref.refresh(trendingProvider.future);
        } catch (_) {}
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: [
          SliverToBoxAdapter(
            child: Stack(
              children: [
                trending.when(
                  data: (items) => items.isEmpty
                      ? const SizedBox(height: 120)
                      : HeroCarousel(
                          items: items,
                          onDetails: (m) => _open(context, m, 'hero-${m.mediaType.path}-${m.id}'),
                          onWatch: (m) => PlayerScreen.push(context, item: m),
                        ),
                  loading: () => const ShimmerBox(height: 460, radius: 0),
                  error: (e, _) => _HeroError(
                    message: e.toString(),
                    onRetry: () => ref.invalidate(trendingProvider),
                  ),
                ),
                const Positioned(top: 0, left: 0, right: 0, child: _TopBar()),
              ],
            ),
          ),
          SliverList.list(
            children: [
              row('Popular Movies', popularMoviesProvider),
              row('Now Playing', nowPlayingMoviesProvider),
              row('Popular Series', popularTvProvider),
              row('Top Rated Movies', topRatedMoviesProvider),
              row('Top Rated Series', topRatedTvProvider),
              // Space so the floating nav bar never covers the last row.
              SizedBox(height: 110 + MediaQuery.paddingOf(context).bottom),
            ],
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        child: Text(
          'MOVIE HOME',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: 2.4,
            color: AppColors.primary,
          ),
        ),
      ),
    );
  }
}

class _HeroError extends StatelessWidget {
  const _HeroError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 320,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Couldn't load content",
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.mutedForeground),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      ),
    );
  }
}
