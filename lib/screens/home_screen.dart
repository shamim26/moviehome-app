import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_theme.dart';
import '../models/media_item.dart';
import '../providers/home_provider.dart';
import '../services/tmdb_service.dart';
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
    return RefreshIndicator(
      color: AppColors.primary,
      backgroundColor: AppColors.card,
      edgeOffset: MediaQuery.paddingOf(context).top,
      onRefresh: () async {
        ref.read(tmdbServiceProvider).clearMemoryCache();
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
                _HeroCarouselSection(
                  onOpen: _open,
                ),
                const Positioned(top: 0, left: 0, right: 0, child: _TopBar()),
              ],
            ),
          ),
          SliverList.list(
            children: [
              _HomeMediaRow(
                title: 'Popular Movies',
                provider: popularMoviesProvider,
                onItemTap: (m, tag) => _open(context, m, tag),
              ),
              _HomeMediaRow(
                title: 'Now Playing',
                provider: nowPlayingMoviesProvider,
                onItemTap: (m, tag) => _open(context, m, tag),
              ),
              _HomeMediaRow(
                title: 'Popular Series',
                provider: popularTvProvider,
                onItemTap: (m, tag) => _open(context, m, tag),
              ),
              _HomeMediaRow(
                title: 'Top Rated Movies',
                provider: topRatedMoviesProvider,
                onItemTap: (m, tag) => _open(context, m, tag),
              ),
              _HomeMediaRow(
                title: 'Top Rated Series',
                provider: topRatedTvProvider,
                onItemTap: (m, tag) => _open(context, m, tag),
              ),
              // Space so the floating nav bar never covers the last row.
              SizedBox(height: 110 + MediaQuery.paddingOf(context).bottom),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroCarouselSection extends ConsumerWidget {
  const _HeroCarouselSection({required this.onOpen});

  final void Function(BuildContext context, MediaItem item, [String? heroTag])
      onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trending = ref.watch(trendingProvider);
    return RepaintBoundary(
      child: trending.when(
        data: (items) => items.isEmpty
            ? const SizedBox(height: 120)
            : HeroCarousel(
                items: items,
                onDetails: (m) =>
                    onOpen(context, m, 'hero-${m.mediaType.path}-${m.id}'),
                onWatch: (m) => PlayerScreen.push(context, item: m),
              ),
        loading: () => const ShimmerBox(height: 460, radius: 0),
        error: (e, _) => _HeroError(
          message: e.toString(),
          onRetry: () => ref.invalidate(trendingProvider),
        ),
      ),
    );
  }
}

class _HomeMediaRow extends ConsumerWidget {
  const _HomeMediaRow({
    required this.title,
    required this.provider,
    required this.onItemTap,
  });

  final String title;
  final FutureProvider<List<MediaItem>> provider;
  final void Function(MediaItem item, String heroTag) onItemTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(provider);
    return RepaintBoundary(
      child: AsyncMediaRow(
        title: title,
        isLoading: async.isLoading && !async.hasValue,
        error: async.hasError && !async.hasValue ? async.error : null,
        items: async.value ?? const [],
        onItemTap: onItemTap,
        onRetry: () => ref.invalidate(provider),
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
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/images/app_logo.png',
                height: 32,
                width: 32,
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'MOVIE HOME',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 2.2,
                color: AppColors.primary,
              ),
            ),
          ],
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
