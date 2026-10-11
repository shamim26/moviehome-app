import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../config/app_theme.dart';
import '../models/media_item.dart';
import '../providers/home_provider.dart';
import '../services/tmdb_service.dart';
import '../widgets/common/media_card.dart';
import '../widgets/common/shimmer_box.dart';
import 'detail_screen.dart';

enum SearchFilter {
  all('All'),
  movies('Movies'),
  series('Series');

  const SearchFilter(this.label);
  final String label;
}

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, this.isTab = false});

  final bool isTab;

  static Future<void> push(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SearchScreen()),
    );
  }

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  Timer? _debounceTimer;
  int _searchGeneration = 0;

  String _query = '';
  SearchFilter _selectedFilter = SearchFilter.all;

  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _errorMessage;

  List<MediaItem> _results = [];
  int _currentPage = 1;
  int _totalPages = 1;
  int _totalResults = 0;

  static const List<String> _popularSuggestions = [
    'Batman',
    'Deadpool',
    'Spider-Man',
    'Anime',
    'Stranger Things',
    'Inception',
    'Horror',
    'Sci-Fi',
  ];

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  void _onQueryChanged(String text) {
    _debounceTimer?.cancel();
    final trimmed = text.trim();
    if (trimmed == _query) return;

    if (trimmed.isEmpty) {
      setState(() {
        _query = '';
        _results = [];
        _isLoading = false;
        _errorMessage = null;
        _currentPage = 1;
        _totalPages = 1;
        _totalResults = 0;
      });
      return;
    }

    _debounceTimer = Timer(const Duration(milliseconds: 350), () {
      _performSearch(trimmed);
    });
  }

  Future<void> _performSearch(String query, {int page = 1}) async {
    final gen = ++_searchGeneration;
    setState(() {
      _query = query;
      _isLoading = true;
      _errorMessage = null;
      if (page == 1) {
        _results = [];
        _currentPage = 1;
      }
    });

    try {
      final tmdb = ref.read(tmdbServiceProvider);
      final response = await tmdb.search(query, page: page);

      if (!mounted || gen != _searchGeneration) return;

      setState(() {
        _isLoading = false;
        _currentPage = response.page;
        _totalPages = response.totalPages;
        _totalResults = response.totalResults;
        _results = response.items;
      });
    } catch (e) {
      if (!mounted || gen != _searchGeneration) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to load search results. Please check your connection.';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || _isLoading || _currentPage >= _totalPages || _query.isEmpty) {
      return;
    }

    setState(() => _isLoadingMore = true);
    final nextPage = _currentPage + 1;

    try {
      final tmdb = ref.read(tmdbServiceProvider);
      final response = await tmdb.search(_query, page: nextPage);

      if (!mounted) return;

      setState(() {
        _isLoadingMore = false;
        _currentPage = response.page;
        _totalPages = response.totalPages;
        _totalResults = response.totalResults;
        final newItems = response.items.where(
          (ni) => !_results.any((r) => r.id == ni.id && r.mediaType == ni.mediaType),
        );
        _results.addAll(newItems);
      });
    } catch (_) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  void _applyQuickSuggestion(String suggestion) {
    _controller.text = suggestion;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: suggestion.length),
    );
    _onQueryChanged(suggestion);
  }

  List<MediaItem> get _filteredResults {
    switch (_selectedFilter) {
      case SearchFilter.all:
        return _results;
      case SearchFilter.movies:
        return _results.where((m) => m.mediaType == MediaType.movie).toList();
      case SearchFilter.series:
        return _results.where((m) => m.mediaType == MediaType.tv).toList();
    }
  }

  double get _bottomNavInset =>
      widget.isTab ? 110 + MediaQuery.paddingOf(context).bottom : 24;

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredResults;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // 1. Search Header Bar
            Padding(
              padding: EdgeInsets.fromLTRB(widget.isTab ? 16 : 8, 8, 16, 8),
              child: Row(
                children: [
                  if (!widget.isTab)
                    IconButton(
                      icon: const Icon(
                        LucideIcons.arrowLeft,
                        color: AppColors.foreground,
                        size: 22,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  Expanded(
                    child: Container(
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppColors.card,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        autofocus: !widget.isTab,
                        textInputAction: TextInputAction.search,
                        style: const TextStyle(
                          color: AppColors.foreground,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                        onChanged: _onQueryChanged,
                        onSubmitted: (val) {
                          _debounceTimer?.cancel();
                          if (val.trim().isNotEmpty) {
                            _performSearch(val.trim());
                          }
                        },
                        decoration: InputDecoration(
                          hintText: 'Search movies, series...',
                          hintStyle: const TextStyle(
                            color: AppColors.mutedForeground,
                            fontSize: 14,
                          ),
                          prefixIcon: const Icon(
                            LucideIcons.search,
                            color: AppColors.primary,
                            size: 18,
                          ),
                          suffixIcon: _controller.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(
                                    LucideIcons.x,
                                    color: AppColors.mutedForeground,
                                    size: 16,
                                  ),
                                  onPressed: () {
                                    _controller.clear();
                                    _onQueryChanged('');
                                  },
                                )
                              : null,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // 2. Filter Chips (shown when a search query is active)
            if (_query.isNotEmpty && !_isLoading && _results.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    for (final filter in SearchFilter.values) ...[
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(filter.label),
                          selected: _selectedFilter == filter,
                          onSelected: (val) {
                            if (val) setState(() => _selectedFilter = filter);
                          },
                          backgroundColor: AppColors.card,
                          selectedColor: AppColors.primary,
                          side: BorderSide(
                            color: _selectedFilter == filter
                                ? AppColors.primary
                                : AppColors.border,
                          ),
                          labelStyle: TextStyle(
                            color: _selectedFilter == filter
                                ? Colors.white
                                : AppColors.mutedForeground,
                            fontSize: 12,
                            fontWeight: _selectedFilter == filter
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    if (_totalResults > 0)
                      Text(
                        '${filtered.length} of $_totalResults',
                        style: const TextStyle(
                          color: AppColors.mutedForeground,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),

            // 3. Search Body (Results / Shimmer / Empty State / Suggestions)
            Expanded(
              child: _buildBody(filtered),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(List<MediaItem> filtered) {
    if (_isLoading) {
      return _buildShimmerGrid();
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
                size: 48,
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
                onPressed: () => _performSearch(_query),
                icon: const Icon(LucideIcons.rotateCw, size: 16),
                label: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    if (_query.isEmpty) {
      return _buildSuggestionsAndTrending();
    }

    if (filtered.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.card,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.border),
                ),
                child: const Icon(
                  LucideIcons.searchX,
                  size: 40,
                  color: AppColors.mutedForeground,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'No results for "$_query"',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.foreground,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Check the spelling or try searching for another movie or series title.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.mutedForeground,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return GridView.builder(
      controller: _scrollController,
      padding: EdgeInsets.fromLTRB(16, 8, 16, _bottomNavInset),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 10,
        mainAxisSpacing: 16,
        childAspectRatio: 0.54,
      ),
      itemCount: filtered.length + (_isLoadingMore ? 3 : 0),
      itemBuilder: (context, index) {
        if (index >= filtered.length) {
          return const ShimmerBox(radius: 12);
        }

        final item = filtered[index];
        final heroTag = MediaCard.heroTag('search', item);

        return MediaCard(
          item: item,
          heroPrefix: 'search',
          onTap: () => DetailScreen.push(context, item, heroTag),
        );
      },
    );
  }

  Widget _buildSuggestionsAndTrending() {
    final trendingAsync = ref.watch(trendingProvider);

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 8, 16, _bottomNavInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Suggestions Chips Header
          Row(
            children: [
              const Icon(
                LucideIcons.sparkles,
                size: 16,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              Text(
                'Top Suggestions',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.foreground,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final suggestion in _popularSuggestions)
                ActionChip(
                  label: Text(suggestion),
                  onPressed: () => _applyQuickSuggestion(suggestion),
                  backgroundColor: AppColors.card,
                  side: const BorderSide(color: AppColors.border),
                  labelStyle: const TextStyle(
                    color: AppColors.foreground,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 28),

          // Trending Now Section
          Row(
            children: [
              const Icon(
                LucideIcons.flame,
                size: 16,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              Text(
                'Trending Today',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.foreground,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          trendingAsync.when(
            data: (items) {
              if (items.isEmpty) return const SizedBox.shrink();
              final displayItems = items.take(12).toList();
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 16,
                  childAspectRatio: 0.54,
                ),
                itemCount: displayItems.length,
                itemBuilder: (context, index) {
                  final item = displayItems[index];
                  final heroTag = MediaCard.heroTag('search-trend', item);
                  return MediaCard(
                    item: item,
                    heroPrefix: 'search-trend',
                    onTap: () => DetailScreen.push(context, item, heroTag),
                  );
                },
              );
            },
            loading: () => _buildShimmerGrid(count: 6, shrinkWrap: true),
            error: (err, stack) => const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildShimmerGrid({int count = 9, bool shrinkWrap = false}) {
    return GridView.builder(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        shrinkWrap ? 24 : _bottomNavInset,
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 10,
        mainAxisSpacing: 16,
        childAspectRatio: 0.54,
      ),
      itemCount: count,
      itemBuilder: (context, index) => const ShimmerBox(radius: 12),
    );
  }
}
