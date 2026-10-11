import 'package:flutter/foundation.dart';
import '../../../models/extracted_stream.dart';
import '../../../models/media_item.dart';
import '../moviebox/moviebox_service.dart';

/// Central subtitle resolver for all CloudStream providers.
/// Ensures all servers (including 4KHDHub, FastCloud, SoraStream, etc.)
/// have full multilingual subtitles even when raw direct MKV/CDN links
/// do not provide their own external WebVTT captions.
class SubtitleResolver {
  SubtitleResolver._();
  static final SubtitleResolver instance = SubtitleResolver._();

  static final Map<String, List<SubtitleTrack>> _cache = {};

  /// Resolves multilingual subtitles for a given title.
  Future<List<SubtitleTrack>> resolveSubtitles({
    required String title,
    int? tmdbId,
    int? year,
    required MediaType type,
    int season = 1,
    int episode = 1,
  }) async {
    final cacheKey = '${title.toLowerCase().trim()}-$season-$episode';
    if (_cache.containsKey(cacheKey) && _cache[cacheKey]!.isNotEmpty) {
      return _cache[cacheKey]!;
    }

    try {
      final subs = await MovieBoxService.instance.fetchSubtitles(
        title: title,
        year: year,
        type: type,
        season: season,
        episode: episode,
      );

      if (subs.isNotEmpty) {
        _cache[cacheKey] = subs;
        debugPrint('[SubtitleResolver] Resolved ${subs.length} subtitle tracks for "$title"');
        return subs;
      }
    } catch (e) {
      debugPrint('[SubtitleResolver] Error fetching subtitles for "$title": $e');
    }

    return [];
  }
}
