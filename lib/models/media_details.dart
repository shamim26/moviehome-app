import 'media_item.dart';

class CastMember {
  const CastMember({
    required this.id,
    required this.name,
    required this.character,
    this.profilePath,
  });

  final int id;
  final String name;
  final String character;
  final String? profilePath;

  factory CastMember.fromJson(Map<String, dynamic> json) => CastMember(
        id: json['id'] as int,
        name: json['name'] as String? ?? '',
        character: json['character'] as String? ?? '',
        profilePath: json['profile_path'] as String?,
      );
}

class Video {
  const Video({
    required this.key,
    required this.name,
    required this.site,
    required this.type,
  });

  final String key;
  final String name;
  final String site;
  final String type;

  bool get isYouTubeTrailer => site == 'YouTube' && type == 'Trailer';

  factory Video.fromJson(Map<String, dynamic> json) => Video(
        key: json['key'] as String? ?? '',
        name: json['name'] as String? ?? '',
        site: json['site'] as String? ?? '',
        type: json['type'] as String? ?? '',
      );
}

class SeasonInfo {
  const SeasonInfo({
    required this.id,
    required this.name,
    required this.seasonNumber,
    required this.episodeCount,
    this.posterPath,
  });

  final int id;
  final String name;
  final int seasonNumber;
  final int episodeCount;
  final String? posterPath;

  factory SeasonInfo.fromJson(Map<String, dynamic> json) => SeasonInfo(
        id: json['id'] as int,
        name: json['name'] as String? ?? '',
        seasonNumber: json['season_number'] as int? ?? 0,
        episodeCount: json['episode_count'] as int? ?? 0,
        posterPath: json['poster_path'] as String?,
      );
}

/// Full detail model for the detail screen (movie or TV).
class MediaDetails {
  const MediaDetails({
    required this.item,
    this.genres = const [],
    this.runtime,
    this.tagline,
    this.numberOfSeasons,
    this.numberOfEpisodes,
    this.seasons = const [],
    this.videos = const [],
    this.cast = const [],
    this.recommendations = const [],
  });

  final MediaItem item;
  final List<Genre> genres;
  final int? runtime;
  final String? tagline;
  final int? numberOfSeasons;
  final int? numberOfEpisodes;
  final List<SeasonInfo> seasons;
  final List<Video> videos;
  final List<CastMember> cast;
  final List<MediaItem> recommendations;

  Video? get trailer {
    for (final v in videos) {
      if (v.isYouTubeTrailer) return v;
    }
    return null;
  }

  factory MediaDetails.fromJson(
    Map<String, dynamic> json,
    MediaType type,
  ) {
    List<T> list<T>(dynamic raw, T Function(Map<String, dynamic>) map) =>
        (raw as List? ?? const [])
            .map((e) => map(e as Map<String, dynamic>))
            .toList();

    final recs = json['recommendations']?['results'];
    final tagline = json['tagline'] as String?;

    return MediaDetails(
      item: MediaItem.fromJson(json, forced: type),
      genres: list(json['genres'], Genre.fromJson),
      runtime: json['runtime'] as int?,
      tagline: (tagline == null || tagline.isEmpty) ? null : tagline,
      numberOfSeasons: json['number_of_seasons'] as int?,
      numberOfEpisodes: json['number_of_episodes'] as int?,
      seasons: list(json['seasons'], SeasonInfo.fromJson)
          .where((s) => s.seasonNumber > 0)
          .toList(),
      videos: list(json['videos']?['results'], Video.fromJson),
      cast: list(json['credits']?['cast'], CastMember.fromJson)
          .take(20)
          .toList(),
      recommendations: (recs as List? ?? const [])
          .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
          .where((m) => m.posterPath != null)
          .toList(),
    );
  }
}
