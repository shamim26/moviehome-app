import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../../config/app_theme.dart';

/// Rounded shimmering placeholder used while content loads.
class ShimmerBox extends StatelessWidget {
  const ShimmerBox({super.key, this.width, this.height, this.radius = 12});

  final double? width;
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppColors.secondary,
      highlightColor: AppColors.accent,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: AppColors.secondary,
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}

/// Skeleton for a horizontal [MediaRow] while it loads.
class MediaRowSkeleton extends StatelessWidget {
  const MediaRowSkeleton({super.key, this.cardWidth = 130});

  final double cardWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: cardWidth * 1.5,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: 6,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (_, _) =>
            ShimmerBox(width: cardWidth, height: cardWidth * 1.5),
      ),
    );
  }
}
