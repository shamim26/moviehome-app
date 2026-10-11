import 'package:flutter_application_1/models/media_item.dart';
import '../models/cloudstream_models.dart';

/// Base class for all streaming providers.
/// Ported from com.lagradost.cloudstream3.MainAPI
abstract class MainAPI {
  /// Unique provider ID (e.g. 'moviebox', '4khdhub', 'superembed', 'vidsrc')
  String get id;

  /// User-facing provider name
  String get name;

  /// Quality or speed summary
  String get qualityBadge => 'HD';

  /// Primary host for this provider
  String get mainUrl;

  /// Types of content supported (movies, tv series)
  Set<MediaType> get supportedTypes => {MediaType.movie, MediaType.tv};

  /// Searches the provider for matching titles
  Future<List<CloudStreamSearchResponse>> search(String query, {int? year, MediaType? type}) async {
    return [];
  }

  /// Loads full details / episodes from a provider media URL
  Future<CloudStreamLoadResponse?> load(String url) async {
    return null;
  }

  /// Resolves direct stream links for a movie or TV episode using TMDB metadata or provider links.
  Future<List<CloudStreamExtractorLink>> loadLinks({
    required int tmdbId,
    required String title,
    int? year,
    required MediaType type,
    int season = 1,
    int episode = 1,
  });
}
