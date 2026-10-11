import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../config/app_theme.dart';
import '../models/media_item.dart';
import '../services/tmdb_service.dart';
import '../widgets/common/media_card.dart';
import '../widgets/common/shimmer_box.dart';
import 'detail_screen.dart';

class _MovieFilter {
  const _MovieFilter({
    required this.label,
    this.category,
    this.genreId,
  });

  final String label;
  final String? category;
  final int? genreId;
}

class MoviesScreen extends ConsumerStatefulWidget {
  const MoviesScreen({super.key});

  @override
  ConsumerState<MoviesScreen> createState() => _MoviesScreenState();
}

class _MoviesScreenState extends ConsumerState<MoviesScreen> {
  final ScrollController _scrollController = ScrollController();

  static const List<_MovieFilter> _filters = [
    _MovieFilter(label: 'Popular', category: 'popular'),
    _MovieFilter(label: 'Top Rated', category: 'top_rated'),
    _MovieFilter(label: 'Now Playing', category: 'now_playing'),
    _MovieFilter(label: 'Upcoming', category: 'upcoming'),
    _MovieFilter(label: 'Action', genreId: 28),
    _MovieFilter(label: 'Sci-Fi', genreId: 878),
    _MovieFilter(label: 'Comedy', genreId: 35),
    _MovieFilter(label: 'Horror', genreId: 27),
    _MovieFilter(label: 'Animation', genreId: 16),
    _MovieFilter(label: 'Drama', genreId: 18),
    _MovieFilter(label: 'Adventure', genreId: 12),
    _MovieFilter(label: 'Fantasy', genreId: 14),
  ];

  int _selectedFilterIndex = 0;
  bool _isLoading = true;
  bool _isLoadingMore = false;
  String? _errorMessage;

  List<MediaItem> _items = [];
  int _currentPage = 1;
  int _totalPages = 1;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadInitial();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 350) {
      _loadMore();
    }
  }

  Future<void> _loadInitial() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _items = [];
      _currentPage = 1;
      _totalPages = 1;
    });

    final currentFilter = _filters[_selectedFilterIndex];

    try {
      final tmdb = ref.read(tmdbServiceProvider);
      final res = await tmdb.fetchMoviesPaginated(
        page: 1,
        category: currentFilter.category ?? 'popular',
        genreId: currentFilter.genreId,
      );

      if (!mounted) return;

      setState(() {
        _isLoading = false;
        _items = res.items;
        _currentPage = res.page;
        _totalPages = res.totalPages;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to load movies. Please check your connection.';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || _isLoading || _currentPage >= _totalPages) return;

    setState(() => _isLoadingMore = true);
    final nextPage = _currentPage + 1;
    final currentFilter = _filters[_selectedFilterIndex];

    try {
      final tmdb = ref.read(tmdbServiceProvider);
      final res = await tmdb.fetchMoviesPaginated(
        page: nextPage,
        category: currentFilter.category ?? 'popular',
        genreId: currentFilter.genreId,
      );

      if (!mounted) return;

      setState(() {
        _isLoadingMore = false;
        _currentPage = res.page;
        _totalPages = res.totalPages;
        final newItems = res.items.where(
          (ni) => !_items.any((ex) => ex.id == ni.id),
        );
        _items.addAll(newItems);
      });
    } catch (_) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  void _onFilterSelected(int index) {
    if (_selectedFilterIndex == index) return;
    setState(() => _selectedFilterIndex = index);
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    _loadInitial();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = 110 + MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Text(
                'Movies',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  color: AppColors.foreground,
                ),
              ),
            ),

            // Horizontal Filter Chips
            SizedBox(
              height: 42,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: _filters.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final filter = _filters[i];
                  final isSelected = i == _selectedFilterIndex;
                  return ChoiceChip(
                    label: Text(filter.label),
                    selected: isSelected,
                    onSelected: (_) => _onFilterSelected(i),
                    backgroundColor: AppColors.card,
                    selectedColor: AppColors.primary,
                    side: BorderSide(
                      color: isSelected ? AppColors.primary : AppColors.border,
                    ),
                    labelStyle: TextStyle(
                      color: isSelected ? Colors.white : AppColors.mutedForeground,
                      fontSize: 12.5,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),

            // Content Area
            Expanded(
              child: _buildBody(bottomInset),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(double bottomInset) {
    if (_isLoading) {
      return GridView.builder(
        padding: EdgeInsets.fromLTRB(16, 8, 16, bottomInset),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 10,
          mainAxisSpacing: 16,
          childAspectRatio: 0.54,
        ),
        itemCount: 9,
        itemBuilder: (_, _) => const ShimmerBox(radius: 12),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                LucideIcons.alertCircle,
                size: 46,
                color: AppColors.destructive,
              ),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.foreground,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadInitial,
                icon: const Icon(LucideIcons.rotateCw, size: 16),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      color: AppColors.primary,
      backgroundColor: AppColors.card,
      onRefresh: _loadInitial,
      child: GridView.builder(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: EdgeInsets.fromLTRB(16, 8, 16, bottomInset),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 10,
          mainAxisSpacing: 16,
          childAspectRatio: 0.54,
        ),
        itemCount: _items.length + (_isLoadingMore ? 3 : 0),
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            return const ShimmerBox(radius: 12);
          }

          final item = _items[index];
          final heroTag = MediaCard.heroTag('movies', item);

          return MediaCard(
            item: item,
            heroPrefix: 'movies',
            onTap: () => DetailScreen.push(context, item, heroTag),
          );
        },
      ),
    );
  }
}
