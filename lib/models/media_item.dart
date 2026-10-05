enum MediaType {
  movie,
  tv;

  String get path => name;

  static MediaType fromString(String? value, {bool hasTitle = true}) {
    if (value == 'tv') return MediaType.tv;
    if (value == 'movie') return MediaType.movie;
    return hasTitle ? MediaType.movie : MediaType.tv;
  }
}

class Genre {
  const Genre({required this.id, required this.name});

  final int id;
  final String name;

  factory Genre.fromJson(Map<String, dynamic> json) =>
      Genre(id: json['id'] as int, name: json['name'] as String? ?? '');
}

/// Lightweight card-level model shared by movies and TV shows.
class MediaItem {
  const MediaItem({
    required this.id,
    required this.title,
    required this.overview,
    required this.mediaType,
    this.posterPath,
    this.backdropPath,
    this.releaseDate = '',
    this.voteAverage = 0,
    this.voteCount = 0,
    this.popularity = 0,
    this.genreIds = const [],
  });

  final int id;
  final String title;
  final String overview;
  final MediaType mediaType;
  final String? posterPath;
  final String? backdropPath;
  final String releaseDate;
  final double voteAverage;
  final int voteCount;
  final double popularity;
  final List<int> genreIds;

  String get year =>
      releaseDate.length >= 4 ? releaseDate.substring(0, 4) : '';

  factory MediaItem.fromJson(Map<String, dynamic> json, {MediaType? forced}) {
    final hasTitle = json['title'] != null;
    final type = forced ??
        MediaType.fromString(json['media_type'] as String?, hasTitle: hasTitle);
    return MediaItem(
      id: json['id'] as int,
      title: (json['title'] ?? json['name'] ?? 'Untitled') as String,
      overview: json['overview'] as String? ?? '',
      mediaType: type,
      posterPath: json['poster_path'] as String?,
      backdropPath: json['backdrop_path'] as String?,
      releaseDate:
          (json['release_date'] ?? json['first_air_date'] ?? '') as String,
      voteAverage: (json['vote_average'] as num?)?.toDouble() ?? 0,
      voteCount: (json['vote_count'] as int?) ?? 0,
      popularity: (json['popularity'] as num?)?.toDouble() ?? 0,
      genreIds: (json['genre_ids'] as List?)?.cast<int>() ?? const [],
    );
  }

  /// Used by the watchlist to persist items locally.
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'overview': overview,
        'media_type': mediaType.path,
        'poster_path': posterPath,
        'backdrop_path': backdropPath,
        'release_date': releaseDate,
        'vote_average': voteAverage,
        'vote_count': voteCount,
        'popularity': popularity,
        'genre_ids': genreIds,
      };
}

class PaginatedMedia {
  const PaginatedMedia({
    required this.items,
    required this.page,
    required this.totalPages,
    this.totalResults = 0,
  });

  static const empty = PaginatedMedia(items: [], page: 1, totalPages: 0);

  final List<MediaItem> items;
  final int page;
  final int totalPages;
  final int totalResults;

  bool get hasMore => page < totalPages;
}
