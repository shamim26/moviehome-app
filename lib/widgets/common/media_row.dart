import 'package:flutter/material.dart';

import '../../config/app_theme.dart';
import '../../models/media_item.dart';
import 'media_card.dart';
import 'shimmer_box.dart';

/// Titled horizontal list of [MediaCard]s that handles its own
/// loading/error states from an [AsyncValue]-like set of inputs.
class MediaRow extends StatelessWidget {
  const MediaRow({
    super.key,
    required this.title,
    required this.items,
    required this.onItemTap,
    this.onSeeAll,
    this.cardWidth = 130,
  });

  final String title;
  final List<MediaItem> items;
  final void Function(MediaItem item, String heroTag) onItemTap;
  final VoidCallback? onSeeAll;
  final double cardWidth;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MediaRowHeader(title: title, onSeeAll: onSeeAll),
        SizedBox(
          height: cardWidth * 1.5 + 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, i) => MediaCard(
              item: items[i],
              width: cardWidth,
              heroPrefix: title,
              onTap: () => onItemTap(
                items[i],
                MediaCard.heroTag(title, items[i]),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class MediaRowHeader extends StatelessWidget {
  const MediaRowHeader({super.key, required this.title, this.onSeeAll});

  final String title;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 8, 12),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 18,
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          if (onSeeAll != null)
            TextButton(
              onPressed: onSeeAll,
              child: const Text(
                'See all',
                style: TextStyle(color: AppColors.mutedForeground),
              ),
            ),
        ],
      ),
    );
  }
}

/// Convenience wrapper that renders a [MediaRow] from an async value's states.
class AsyncMediaRow extends StatelessWidget {
  const AsyncMediaRow({
    super.key,
    required this.title,
    required this.isLoading,
    required this.error,
    required this.items,
    required this.onItemTap,
    required this.onRetry,
    this.onSeeAll,
  });

  final String title;
  final bool isLoading;
  final Object? error;
  final List<MediaItem> items;
  final void Function(MediaItem item, String heroTag) onItemTap;
  final VoidCallback onRetry;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MediaRowHeader(title: title),
          const MediaRowSkeleton(),
        ],
      );
    }
    if (error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MediaRowHeader(title: title),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Icon(Icons.wifi_off_rounded,
                    color: AppColors.mutedForeground),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    "Couldn't load this section",
                    style: TextStyle(color: AppColors.mutedForeground),
                  ),
                ),
                TextButton(onPressed: onRetry, child: const Text('Retry')),
              ],
            ),
          ),
        ],
      );
    }
    if (items.isEmpty) return const SizedBox.shrink();
    return MediaRow(
      title: title,
      items: items,
      onItemTap: onItemTap,
      onSeeAll: onSeeAll,
    );
  }
}
