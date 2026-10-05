import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../config/app_theme.dart';
import '../config/constants.dart';
import '../models/media_details.dart';
import '../models/media_item.dart';
import '../providers/media_detail_provider.dart';
import '../providers/watchlist_provider.dart';
import '../widgets/common/media_card.dart';
import '../widgets/common/shimmer_box.dart';
import '../services/storage_service.dart';
import 'player_screen.dart';

class DetailScreen extends ConsumerWidget {
  const DetailScreen({
    super.key,
    required this.item,
    this.heroTag,
  });

  final MediaItem item;
  final String? heroTag;

  static void push(BuildContext context, MediaItem item, [String? heroTag]) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailScreen(item: item, heroTag: heroTag),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(
      mediaDetailsProvider((id: item.id, type: item.mediaType)),
    );
    final isBookmarked = ref.watch(
      watchlistProvider.select(
        (list) => list.any((m) => m.id == item.id && m.mediaType == item.mediaType),
      ),
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      body: detailAsync.when(
        data: (details) => _DetailContent(
          details: details,
          item: item,
          heroTag: heroTag,
          isBookmarked: isBookmarked,
        ),
        loading: () => _DetailSkeleton(item: item, heroTag: heroTag),
        error: (error, _) => _DetailError(
          item: item,
          error: error.toString(),
          onRetry: () => ref.invalidate(
            mediaDetailsProvider((id: item.id, type: item.mediaType)),
          ),
        ),
      ),
    );
  }
}

class _DetailContent extends ConsumerStatefulWidget {
  const _DetailContent({
    required this.details,
    required this.item,
    required this.heroTag,
    required this.isBookmarked,
  });

  final MediaDetails details;
  final MediaItem item;
  final String? heroTag;
  final bool isBookmarked;

  @override
  ConsumerState<_DetailContent> createState() => _DetailContentState();
}

class _DetailContentState extends ConsumerState<_DetailContent> {
  int _selectedSeason = 1;
  int _selectedEpisode = 1;

  @override
  void initState() {
    super.initState();
    final progress = ref.read(storageServiceProvider).getWatchProgress(
          widget.item.id,
          widget.item.mediaType,
        );
    if (progress != null) {
      if (progress['season'] is int) {
        _selectedSeason = progress['season'] as int;
      }
      if (progress['episode'] is int) {
        _selectedEpisode = progress['episode'] as int;
      }
    }
  }

  void _onPlay() {
    PlayerScreen.push(
      context,
      item: widget.item,
      season: _selectedSeason,
      episode: _selectedEpisode,
      seasons: widget.details.seasons,
    );
  }

  @override
  Widget build(BuildContext context) {
    final details = widget.details;
    final item = widget.item;
    final textTheme = Theme.of(context).textTheme;
    final backdropUrl = tmdbImageUrl(
      item.backdropPath ?? item.posterPath,
      size: TmdbImageSize.w1280,
    );
    final posterUrl = tmdbImageUrl(
      item.posterPath,
      size: TmdbImageSize.w500,
    );

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverAppBar(
          expandedHeight: 320,
          pinned: true,
          backgroundColor: AppColors.background,
          elevation: 0,
          leading: Padding(
            padding: const EdgeInsets.all(8.0),
            child: CircleAvatar(
              backgroundColor: Colors.black54,
              child: IconButton(
                icon: const Icon(LucideIcons.arrowLeft, color: Colors.white, size: 20),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: CircleAvatar(
                backgroundColor: Colors.black54,
                child: IconButton(
                  icon: Icon(
                    widget.isBookmarked ? LucideIcons.bookmarkCheck : LucideIcons.bookmark,
                    color: widget.isBookmarked ? AppColors.primary : Colors.white,
                    size: 20,
                  ),
                  onPressed: () => ref.read(watchlistProvider.notifier).toggle(item),
                ),
              ),
            ),
          ],
          flexibleSpace: FlexibleSpaceBar(
            background: Stack(
              fit: StackFit.expand,
              children: [
                if (backdropUrl.isNotEmpty)
                  CachedNetworkImage(
                    imageUrl: backdropUrl,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => const ColoredBox(color: AppColors.secondary),
                    errorWidget: (_, _, _) => const ColoredBox(color: AppColors.secondary),
                  ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0.0, 0.4, 0.75, 1.0],
                      colors: [
                        Colors.black45,
                        Colors.transparent,
                        Color(0xB3090A0F),
                        AppColors.background,
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header with Poster + Title & Metas
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Hero(
                      tag: widget.heroTag ?? 'detail-${item.mediaType.path}-${item.id}',
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: 105,
                          height: 155,
                          child: posterUrl.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: posterUrl,
                                  fit: BoxFit.cover,
                                  placeholder: (_, _) => const ShimmerBox(radius: 0),
                                  errorWidget: (_, _, _) => const ColoredBox(color: AppColors.secondary),
                                )
                              : const ColoredBox(color: AppColors.secondary),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            style: textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                              height: 1.15,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (details.tagline != null) ...[
                            Text(
                              '"${details.tagline}"',
                              style: textTheme.bodySmall?.copyWith(
                                color: AppColors.mutedForeground,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                          Row(
                            children: [
                              const Icon(LucideIcons.star, size: 14, color: AppColors.star),
                              const SizedBox(width: 4),
                              Text(
                                item.voteAverage.toStringAsFixed(1),
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                              ),
                              const SizedBox(width: 10),
                              if (item.year.isNotEmpty) ...[
                                Text(
                                  item.year,
                                  style: const TextStyle(color: AppColors.mutedForeground, fontSize: 13),
                                ),
                                const SizedBox(width: 10),
                              ],
                              if (item.mediaType == MediaType.movie && details.runtime != null)
                                Text(
                                  '${details.runtime! ~/ 60}h ${details.runtime! % 60}m',
                                  style: const TextStyle(color: AppColors.mutedForeground, fontSize: 13),
                                )
                              else if (item.mediaType == MediaType.tv && details.numberOfSeasons != null)
                                Text(
                                  '${details.numberOfSeasons} Seasons',
                                  style: const TextStyle(color: AppColors.mutedForeground, fontSize: 13),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Genre Chips
                if (details.genres.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: details.genres.map((g) {
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: AppColors.secondary,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Text(
                          g.name,
                          style: const TextStyle(fontSize: 11.5, color: AppColors.foreground),
                        ),
                      );
                    }).toList(),
                  ),
                const SizedBox(height: 20),

                // Action Buttons: Watch Now & Watchlist
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: FilledButton.icon(
                        onPressed: _onPlay,
                        icon: const Icon(LucideIcons.play, size: 18),
                        label: const Text('Watch Now', style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: OutlinedButton.icon(
                        onPressed: () => ref.read(watchlistProvider.notifier).toggle(item),
                        icon: Icon(
                          widget.isBookmarked ? LucideIcons.bookmarkCheck : LucideIcons.bookmark,
                          size: 18,
                          color: widget.isBookmarked ? AppColors.primary : Colors.white,
                        ),
                        label: Text(
                          widget.isBookmarked ? 'Saved' : 'Watchlist',
                          style: TextStyle(
                            color: widget.isBookmarked ? AppColors.primary : Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(
                            color: widget.isBookmarked ? AppColors.primary : AppColors.border,
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Storyline
                if (item.overview.isNotEmpty) ...[
                  Text(
                    'Storyline',
                    style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    item.overview,
                    style: textTheme.bodyMedium?.copyWith(
                      color: AppColors.foreground.withValues(alpha: 0.85),
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                ],

                // TV Seasons & Episodes picker
                if (item.mediaType == MediaType.tv && details.seasons.isNotEmpty) ...[
                  Text(
                    'Episodes',
                    style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 38,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: details.seasons.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (_, idx) {
                        final s = details.seasons[idx];
                        final isSel = s.seasonNumber == _selectedSeason;
                        return ChoiceChip(
                          label: Text('Season ${s.seasonNumber}'),
                          selected: isSel,
                          onSelected: (_) => setState(() {
                            _selectedSeason = s.seasonNumber;
                            _selectedEpisode = 1;
                          }),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  _EpisodesGrid(
                    season: details.seasons.firstWhere(
                      (s) => s.seasonNumber == _selectedSeason,
                      orElse: () => details.seasons.first,
                    ),
                    selectedEpisode: _selectedEpisode,
                    onSelect: (ep) {
                      setState(() => _selectedEpisode = ep);
                      _onPlay();
                    },
                  ),
                  const SizedBox(height: 24),
                ],

                // Cast Section
                if (details.cast.isNotEmpty) ...[
                  Text(
                    'Top Cast',
                    style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 105,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: details.cast.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 14),
                      itemBuilder: (_, idx) {
                        final member = details.cast[idx];
                        final profileUrl = tmdbImageUrl(member.profilePath, size: TmdbImageSize.w300);
                        return SizedBox(
                          width: 72,
                          child: Column(
                            children: [
                              CircleAvatar(
                                radius: 28,
                                backgroundColor: AppColors.secondary,
                                backgroundImage: profileUrl.isNotEmpty
                                    ? CachedNetworkImageProvider(profileUrl)
                                    : null,
                                child: profileUrl.isEmpty
                                    ? const Icon(LucideIcons.user, size: 22, color: AppColors.mutedForeground)
                                    : null,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                member.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                              ),
                              Text(
                                member.character,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 9.5, color: AppColors.mutedForeground),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 24),
                ],

                // Recommendations
                if (details.recommendations.isNotEmpty) ...[
                  Text(
                    'You May Also Like',
                    style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 195 + 44,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: details.recommendations.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 12),
                      itemBuilder: (_, idx) {
                        final rec = details.recommendations[idx];
                        return MediaCard(
                          item: rec,
                          width: 125,
                          heroPrefix: 'rec',
                          onTap: () => DetailScreen.push(
                            context,
                            rec,
                            MediaCard.heroTag('rec', rec),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _EpisodesGrid extends StatelessWidget {
  const _EpisodesGrid({
    required this.season,
    required this.selectedEpisode,
    required this.onSelect,
  });

  final SeasonInfo season;
  final int selectedEpisode;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final count = season.episodeCount > 0 ? season.episodeCount : 12;
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: count,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, idx) {
          final ep = idx + 1;
          final isSel = ep == selectedEpisode;
          return ActionChip(
            backgroundColor: isSel ? AppColors.primary : AppColors.secondary,
            side: BorderSide(color: isSel ? AppColors.primary : AppColors.border),
            label: Text(
              'EP $ep',
              style: TextStyle(
                fontWeight: isSel ? FontWeight.w800 : FontWeight.w500,
                color: isSel ? Colors.white : AppColors.foreground,
              ),
            ),
            onPressed: () => onSelect(ep),
          );
        },
      ),
    );
  }
}

class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton({required this.item, this.heroTag});

  final MediaItem item;
  final String? heroTag;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: const Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ShimmerBox(height: 180, radius: 12),
            SizedBox(height: 20),
            ShimmerBox(height: 28, width: 220, radius: 6),
            SizedBox(height: 12),
            ShimmerBox(height: 16, width: 140, radius: 4),
            SizedBox(height: 24),
            ShimmerBox(height: 48, radius: 12),
            SizedBox(height: 24),
            ShimmerBox(height: 80, radius: 8),
          ],
        ),
      ),
    );
  }
}

class _DetailError extends StatelessWidget {
  const _DetailError({
    required this.item,
    required this.error,
    required this.onRetry,
  });

  final MediaItem item;
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(LucideIcons.wifiOff, size: 48, color: AppColors.mutedForeground),
              const SizedBox(height: 16),
              const Text(
                "Couldn't load details",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.mutedForeground),
              ),
              const SizedBox(height: 20),
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      ),
    );
  }
}
