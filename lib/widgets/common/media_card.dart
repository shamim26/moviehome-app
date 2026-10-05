import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../config/app_theme.dart';
import '../../config/constants.dart';
import '../../models/media_item.dart';
import 'shimmer_box.dart';

/// Vertical poster card with rating badge. Images are decoded at card size
/// (memCacheWidth) to keep scrolling smooth and memory low.
class MediaCard extends StatelessWidget {
  const MediaCard({
    super.key,
    required this.item,
    required this.onTap,
    this.width = 130,
    this.heroPrefix = 'poster',
  });

  final MediaItem item;
  final VoidCallback onTap;
  final double width;
  final String heroPrefix;

  /// Tag shared between a card poster and the detail screen poster.
  static String heroTag(String prefix, MediaItem item) =>
      '$prefix-${item.mediaType.path}-${item.id}';

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final url = tmdbImageUrl(item.posterPath, size: TmdbImageSize.w342);
    final textTheme = Theme.of(context).textTheme;

    return RepaintBoundary(
      child: SizedBox(
        width: width,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Hero(
                  tag: heroTag(heroPrefix, item),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        url.isEmpty
                            ? const ColoredBox(
                                color: AppColors.secondary,
                                child: Icon(
                                  LucideIcons.clapperboard,
                                  color: AppColors.mutedForeground,
                                ),
                              )
                            : CachedNetworkImage(
                                imageUrl: url,
                                fit: BoxFit.cover,
                                memCacheWidth: (width * dpr).round(),
                                fadeInDuration:
                                    const Duration(milliseconds: 200),
                                placeholder: (_, _) =>
                                    const ShimmerBox(radius: 0),
                                errorWidget: (_, _, _) => const ColoredBox(
                                  color: AppColors.secondary,
                                  child: Icon(
                                    LucideIcons.imageOff,
                                    color: AppColors.mutedForeground,
                                  ),
                                ),
                              ),
                        if (item.voteAverage > 0)
                          Positioned(
                            top: 8,
                            left: 8,
                            child: _RatingBadge(rating: item.voteAverage),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                [
                  if (item.year.isNotEmpty) item.year,
                  item.mediaType == MediaType.tv ? 'Series' : 'Movie',
                ].join(' • '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RatingBadge extends StatelessWidget {
  const _RatingBadge({required this.rating});

  final double rating;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.star, size: 12, color: AppColors.star),
            const SizedBox(width: 3),
            Text(
              rating.toStringAsFixed(1),
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
