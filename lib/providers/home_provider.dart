import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/media_item.dart';
import '../services/tmdb_service.dart';

/// Home-screen rows. Each is cached by Riverpod and auto-disposed when unused.
final trendingProvider = FutureProvider.autoDispose<List<MediaItem>>(
  (ref) => ref.watch(tmdbServiceProvider).trending(),
);

final popularMoviesProvider = FutureProvider.autoDispose<List<MediaItem>>(
  (ref) => ref.watch(tmdbServiceProvider).popularMovies(),
);

final topRatedMoviesProvider = FutureProvider.autoDispose<List<MediaItem>>(
  (ref) => ref.watch(tmdbServiceProvider).topRatedMovies(),
);

final nowPlayingMoviesProvider = FutureProvider.autoDispose<List<MediaItem>>(
  (ref) => ref.watch(tmdbServiceProvider).nowPlayingMovies(),
);

final popularTvProvider = FutureProvider.autoDispose<List<MediaItem>>(
  (ref) => ref.watch(tmdbServiceProvider).popularTv(),
);

final topRatedTvProvider = FutureProvider.autoDispose<List<MediaItem>>(
  (ref) => ref.watch(tmdbServiceProvider).topRatedTv(),
);
