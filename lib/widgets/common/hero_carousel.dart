import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../config/app_theme.dart';
import '../../config/constants.dart';
import '../../config/genres.dart';
import '../../models/media_item.dart';
import 'shimmer_box.dart';

/// Auto-advancing featured banner with backdrop, gradient and quick actions.
class HeroCarousel extends StatefulWidget {
  const HeroCarousel({
    super.key,
    required this.items,
    required this.onDetails,
    this.onWatch,
    this.height = 460,
  });

  final List<MediaItem> items;
  final ValueChanged<MediaItem> onDetails;
  final ValueChanged<MediaItem>? onWatch;
  final double height;

  @override
  State<HeroCarousel> createState() => _HeroCarouselState();
}

class _HeroCarouselState extends State<HeroCarousel> {
  PageController? _controller;
  Timer? _timer;
  int _index = 0;
  bool _isUserInteracting = false;

  List<MediaItem> get _items => widget.items.take(8).toList();

  @override
  void initState() {
    super.initState();
    _initController();
    _startTimer();
  }

  void _initController() {
    final count = _items.length;
    // Set a high base page so it can scroll backwards and forwards endlessly
    final initialPage = count > 1 ? count * 1000 : 0;
    _controller?.dispose();
    _controller = PageController(initialPage: initialPage);
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted || _isUserInteracting) return;
      final controller = _controller;
      if (controller == null || !controller.hasClients || _items.length < 2) return;

      // Always advance 1 page forward relative to current real position
      final currentPage = controller.page?.round() ?? controller.initialPage;
      controller.animateToPage(
        currentPage + 1,
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items.isEmpty) return const SizedBox.shrink();

    final controller = _controller ?? PageController();

    return SizedBox(
      height: widget.height,
      child: Stack(
        children: [
          NotificationListener<UserScrollNotification>(
            onNotification: (notification) {
              if (notification.direction == ScrollDirection.idle) {
                _isUserInteracting = false;
                _startTimer();
              } else {
                _isUserInteracting = true;
                _timer?.cancel();
              }
              return false;
            },
            child: PageView.builder(
              controller: controller,
              onPageChanged: (i) {
                if (items.isNotEmpty) {
                  setState(() => _index = i % items.length);
                }
              },
              itemBuilder: (context, i) {
                final item = items[i % items.length];
                return _HeroSlide(
                  item: item,
                  onDetails: () => widget.onDetails(item),
                  onWatch: widget.onWatch == null
                      ? null
                      : () => widget.onWatch!(item),
                );
              },
            ),
          ),
          Positioned(
            bottom: 14,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < items.length; i++)
                  GestureDetector(
                    onTap: () {
                      final ctrl = _controller;
                      if (ctrl == null || !ctrl.hasClients) return;
                      final currentReal = ctrl.page?.round() ?? ctrl.initialPage;
                      final currentMod = currentReal % items.length;
                      final delta = i - currentMod;
                      ctrl.animateToPage(
                        currentReal + delta,
                        duration: const Duration(milliseconds: 450),
                        curve: Curves.easeInOutCubic,
                      );
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == _index ? 22 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: i == _index
                            ? AppColors.primary
                            : Colors.white.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroSlide extends StatelessWidget {
  const _HeroSlide({
    required this.item,
    required this.onDetails,
    this.onWatch,
  });

  final MediaItem item;
  final VoidCallback onDetails;
  final VoidCallback? onWatch;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // Portrait phones look better with the poster; wide screens use backdrop.
    final usePoster = size.width < 600 && item.posterPath != null;
    final url = usePoster
        ? tmdbImageUrl(item.posterPath, size: TmdbImageSize.w780)
        : tmdbImageUrl(
            item.backdropPath ?? item.posterPath,
            size: TmdbImageSize.w1280,
          );
    final textTheme = Theme.of(context).textTheme;
    final genres = genreNames(item.genreIds).take(3).join(' • ');

    return GestureDetector(
      onTap: onDetails,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            memCacheWidth: (size.width * dpr).round(),
            fadeInDuration: const Duration(milliseconds: 300),
            placeholder: (_, _) => const ShimmerBox(radius: 0),
            errorWidget: (_, _, _) =>
                const ColoredBox(color: AppColors.secondary),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.0, 0.35, 0.75, 1.0],
                colors: [
                  Color(0x99090A0F),
                  Color(0x00090A0F),
                  Color(0xCC090A0F),
                  AppColors.background,
                ],
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 36,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(LucideIcons.star,
                        size: 14, color: AppColors.star),
                    const SizedBox(width: 4),
                    Text(
                      [
                        item.voteAverage.toStringAsFixed(1),
                        if (item.year.isNotEmpty) item.year,
                        if (genres.isNotEmpty) genres,
                      ].join('  •  '),
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.foreground.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: onWatch ?? onDetails,
                      icon: const Icon(LucideIcons.play, size: 18),
                      label: const Text('Watch now'),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: onDetails,
                      icon: const Icon(LucideIcons.info, size: 18),
                      label: const Text('Details'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.4),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
