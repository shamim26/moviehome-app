import 'package:flutter/foundation.dart';
import 'package:flutter_application_1/models/extracted_stream.dart';
import 'package:flutter_application_1/models/media_item.dart';
import 'package:flutter_application_1/models/stream_server.dart';
import '../../moviebox/moviebox_service.dart';
import '../core/main_api.dart';
import '../models/cloudstream_models.dart';

/// CloudStream Server: SuperStream Fast CDN & Multi-Resolution Provider.
/// Resolves multi-quality streams (1080p, 720p, 480p, 360p) with multilingual subtitles.
class SuperStreamMirrorProvider extends MainAPI {
  @override
  String get id => 'superstream_fast';

  @override
  String get name => 'SuperStream';

  @override
  String get qualityBadge => 'Fast CDN / Multi-Res (Direct MP4)';

  @override
  String get mainUrl => 'https://api.inmoviebox.com';

  @override
  Future<List<CloudStreamExtractorLink>> loadLinks({
    required int tmdbId,
    required String title,
    int? year,
    required MediaType type,
    int season = 1,
    int episode = 1,
  }) async {
    debugPrint('[CloudStream:Server3] Resolving "$title" (year: $year, S:$season E:$episode)');

    final stream = await MovieBoxService.instance.getStream(
      title: title,
      year: year,
      type: type,
      season: season,
      episode: episode,
      server: StreamServer(
        id: id,
        name: name,
        quality: qualityBadge,
        host: 'api.inmoviebox.com',
        builder: (id, t, s, e) => 'superstream_fast://$id',
      ),
    );

    if (stream == null) {
      debugPrint('[CloudStream:Server3] Could not resolve stream for "$title"');
      return [];
    }

    // Build multi-quality links
    final qualities = <StreamQuality>[...stream.qualities];
    if (qualities.isEmpty && stream.url.isNotEmpty) {
      qualities.add(StreamQuality(
        label: stream.quality.isNotEmpty ? stream.quality : 'Auto',
        url: stream.url,
      ));
    }

    // Choose primary URL: prefer 1080p or 720p direct stream
    String primaryUrl = stream.url;
    if (qualities.isNotEmpty) {
      primaryUrl = qualities.first.url;
    }

    debugPrint('[CloudStream:Server3] Resolved ${qualities.length} qualities and ${stream.subtitles.length} subtitles');

    return [
      CloudStreamExtractorLink(
        source: name,
        name: 'Fast CDN (${stream.quality.isNotEmpty ? stream.quality : "1080p"})',
        url: primaryUrl,
        referer: stream.headers['Referer'] ?? 'https://sportslive.wine',
        quality: stream.quality.isNotEmpty ? stream.quality : '1080p',
        isM3u8: stream.isHls,
        isDash: primaryUrl.contains('.mpd'),
        headers: stream.headers,
        subtitles: stream.subtitles,
        qualities: qualities,
      ),
    ];
  }
}
