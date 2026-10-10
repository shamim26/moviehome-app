import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/constants.dart';
import '../models/media_details.dart';
import '../models/media_item.dart';

class TmdbException implements Exception {
  const TmdbException(this.message);
  final String message;

  @override
  String toString() => 'TmdbException: $message';
}

/// Anime browse categories (ported from the web client).
enum AnimeCategory { topRated, popular, action, fantasy, scifi }

enum AnimeType { all, tv, movie }

/// TMDB REST client. The API key is injected through [AppConstants] at build
/// time and is attached by an interceptor, so it never appears in call sites.
class TmdbService {
  TmdbService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: AppConstants.tmdbBaseUrl,
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 15),
              ),
            ) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.queryParameters['api_key'] = AppConstants.tmdbApiKey;
          options.queryParameters.putIfAbsent('language', () => 'en-US');
          handler.next(options);
        },
      ),
    );
  }

  final Dio _dio;

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, dynamic>? params,
  ]) async {
    if (!AppConstants.hasApiKey) {
      throw const TmdbException(
        'TMDB API key missing. Run with --dart-define-from-file=env.json',
      );
    }
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        path,
        queryParameters: params,
      );
      return res.data ?? const {};
    } on DioException catch (e) {
      throw TmdbException(e.message ?? 'Network error');
    }
  }

  List<MediaItem> _items(Map<String, dynamic> data, {MediaType? forced}) =>
      (data['results'] as List? ?? const [])
          .map((e) => MediaItem.fromJson(e as Map<String, dynamic>, forced: forced))
          .toList();

  PaginatedMedia _paginated(
    Map<String, dynamic> data,
    int page, {
    MediaType? forced,
  }) {
    final items = _items(data, forced: forced);
    if (items.isEmpty) return PaginatedMedia.empty;
    return PaginatedMedia(
      items: items,
      page: data['page'] as int? ?? page,
      // TMDB caps pagination at 500 pages.
      totalPages: ((data['total_pages'] as int?) ?? 1).clamp(1, 500),
      totalResults: data['total_results'] as int? ?? 0,
    );
  }

  // ── In-Memory Caches for fast navigation & low RAM usage ─────────────
  final Map<String, MediaDetails> _detailsCache = {};
  final List<String> _detailsCacheOrder = [];
  static const int _maxDetailsCacheSize = 40;

  List<MediaItem>? _cachedTrending;
  List<MediaItem>? _cachedPopularMovies;
  List<MediaItem>? _cachedTopRatedMovies;
  List<MediaItem>? _cachedNowPlayingMovies;
  List<MediaItem>? _cachedPopularTv;
  List<MediaItem>? _cachedTopRatedTv;

  /// Clears in-memory caches to free RAM when under memory pressure or refreshing.
  void clearMemoryCache() {
    _detailsCache.clear();
    _detailsCacheOrder.clear();
    _cachedTrending = null;
    _cachedPopularMovies = null;
    _cachedTopRatedMovies = null;
    _cachedNowPlayingMovies = null;
    _cachedPopularTv = null;
    _cachedTopRatedTv = null;
  }

  // ── Home rows ───────────────────────────────────────────────────────────

  Future<List<MediaItem>> trending({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedTrending != null) return _cachedTrending!;
    final items = _items(await _get('/trending/all/day'))
        .where((m) => m.backdropPath != null || m.posterPath != null)
        .toList();
    _cachedTrending = items;
    return items;
  }

  Future<List<MediaItem>> popularMovies({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedPopularMovies != null) return _cachedPopularMovies!;
    final items = _items(await _get('/movie/popular'), forced: MediaType.movie);
    _cachedPopularMovies = items;
    return items;
  }

  Future<List<MediaItem>> topRatedMovies({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedTopRatedMovies != null) return _cachedTopRatedMovies!;
    final items = _items(await _get('/movie/top_rated'), forced: MediaType.movie);
    _cachedTopRatedMovies = items;
    return items;
  }

  Future<List<MediaItem>> nowPlayingMovies({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedNowPlayingMovies != null) return _cachedNowPlayingMovies!;
    final items = _items(await _get('/movie/now_playing'), forced: MediaType.movie);
    _cachedNowPlayingMovies = items;
    return items;
  }

  Future<List<MediaItem>> popularTv({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedPopularTv != null) return _cachedPopularTv!;
    final items = _items(await _get('/tv/popular'), forced: MediaType.tv);
    _cachedPopularTv = items;
    return items;
  }

  Future<List<MediaItem>> topRatedTv({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedTopRatedTv != null) return _cachedTopRatedTv!;
    final items = _items(await _get('/tv/top_rated'), forced: MediaType.tv);
    _cachedTopRatedTv = items;
    return items;
  }

  // ── Browse (paginated) ──────────────────────────────────────────────────

  Future<PaginatedMedia> moviesByLanguage({
    String? langCode,
    int page = 1,
  }) async {
    final data = await _get('/discover/movie', {
      'sort_by': 'popularity.desc',
      'page': page,
      if (langCode != null && langCode != 'all')
        'with_original_language': langCode,
    });
    return _paginated(data, page, forced: MediaType.movie);
  }

  Future<PaginatedMedia> seriesByLanguage({
    String? langCode,
    int page = 1,
  }) async {
    final data = await _get('/discover/tv', {
      'sort_by': 'popularity.desc',
      'page': page,
      if (langCode != null && langCode != 'all')
        'with_original_language': langCode,
    });
    return _paginated(data, page, forced: MediaType.tv);
  }

  Map<String, dynamic> _animeParams(
    AnimeCategory category,
    int page, {
    required bool isMovie,
  }) {
    final action = isMovie ? '28' : '10759';
    final fantasy = isMovie ? '14' : '10765';
    final scifi = isMovie ? '878' : '10765';
    final params = <String, dynamic>{
      'with_genres': '16',
      'with_original_language': 'ja',
      'page': page,
    };
    switch (category) {
      case AnimeCategory.popular:
        params['sort_by'] = 'popularity.desc';
      case AnimeCategory.action:
        params['with_genres'] = '16,$action';
        params['sort_by'] = 'vote_average.desc';
        params['vote_count.gte'] = 50;
      case AnimeCategory.fantasy:
        params['with_genres'] = '16,$fantasy';
        params['sort_by'] = 'vote_average.desc';
        params['vote_count.gte'] = 50;
      case AnimeCategory.scifi:
        params['with_genres'] = '16,$scifi';
        params['sort_by'] = 'vote_average.desc';
        params['vote_count.gte'] = 50;
      case AnimeCategory.topRated:
        params['sort_by'] = 'vote_average.desc';
        params['vote_count.gte'] = 100;
    }
    return params;
  }

  Future<PaginatedMedia> anime({
    AnimeType type = AnimeType.all,
    AnimeCategory category = AnimeCategory.topRated,
    int page = 1,
  }) async {
    if (type == AnimeType.all) {
      final results = await Future.wait([
        _get('/discover/tv', _animeParams(category, page, isMovie: false)),
        _get('/discover/movie', _animeParams(category, page, isMovie: true)),
      ]);
      final tv = _items(results[0], forced: MediaType.tv);
      final movies = _items(results[1], forced: MediaType.movie);
      final combined = [...tv, ...movies]..sort(
          category == AnimeCategory.popular
              ? (a, b) => b.popularity.compareTo(a.popularity)
              : (a, b) => b.voteAverage.compareTo(a.voteAverage),
        );
      int pages(Map<String, dynamic> d) =>
          ((d['total_pages'] as int?) ?? 1).clamp(1, 500);
      return PaginatedMedia(
        items: combined,
        page: page,
        totalPages: pages(results[0]) > pages(results[1])
            ? pages(results[0])
            : pages(results[1]),
        totalResults: (results[0]['total_results'] as int? ?? 0) +
            (results[1]['total_results'] as int? ?? 0),
      );
    }

    final isMovie = type == AnimeType.movie;
    final data = await _get(
      isMovie ? '/discover/movie' : '/discover/tv',
      _animeParams(category, page, isMovie: isMovie),
    );
    return _paginated(
      data,
      page,
      forced: isMovie ? MediaType.movie : MediaType.tv,
    );
  }

  // ── Details & search ────────────────────────────────────────────────────

  Future<MediaDetails> details(int id, MediaType type) async {
    final cacheKey = '${type.path}_$id';
    final cached = _detailsCache[cacheKey];
    if (cached != null) {
      _detailsCacheOrder.remove(cacheKey);
      _detailsCacheOrder.add(cacheKey);
      return cached;
    }

    final data = await _get('/${type.path}/$id', {
      'append_to_response': 'videos,credits,recommendations',
    });
    final result = MediaDetails.fromJson(data, type);

    if (_detailsCacheOrder.length >= _maxDetailsCacheSize) {
      final oldest = _detailsCacheOrder.removeAt(0);
      _detailsCache.remove(oldest);
    }
    _detailsCache[cacheKey] = result;
    _detailsCacheOrder.add(cacheKey);

    return result;
  }

  Future<PaginatedMedia> search(String query, {int page = 1}) async {
    if (query.trim().isEmpty) return PaginatedMedia.empty;
    final data = await _get('/search/multi', {
      'query': query.trim(),
      'page': page,
      'include_adult': false,
    });
    final items = _items(data)
        .where((m) => m.posterPath != null)
        .toList();
    if (items.isEmpty) return PaginatedMedia.empty;
    return PaginatedMedia(
      items: items,
      page: data['page'] as int? ?? page,
      totalPages: data['total_pages'] as int? ?? 1,
      totalResults: data['total_results'] as int? ?? 0,
    );
  }
}

final tmdbServiceProvider = Provider<TmdbService>((ref) => TmdbService());
