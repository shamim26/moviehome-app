import 'package:flutter_application_1/models/media_item.dart';
import '../../fourkhdhub/fourkhdhub_service.dart';
import '../core/main_api.dart';
import '../models/cloudstream_models.dart';
import 'package:flutter_application_1/models/stream_server.dart';

/// CloudStream provider for FastCloud / Edge CDN.
/// Resolves high-speed Cloudflare edge streams with multi-audio.
class FastCloudProvider extends MainAPI {
  @override
  String get id => 'fastcloud';

  @override
  String get name => 'FastCloud';

  @override
  String get qualityBadge => 'High-Speed Edge CDN / Multi-Audio';

  @override
  String get mainUrl => 'https://hubcloud.club';

  @override
  Future<List<CloudStreamExtractorLink>> loadLinks({
    required int tmdbId,
    required String title,
    int? year,
    required MediaType type,
    int season = 1,
    int episode = 1,
  }) async {
    final stream = await FourKHdHubService.instance.getStream(
      title: title,
      year: year,
      type: type,
      season: season,
      episode: episode,
      preferredResolution: 720,
      candidateOffset: 1,
      server: StreamServer(
        id: id,
        name: name,
        quality: qualityBadge,
        host: 'hubcloud.club',
        builder: (id, t, s, e) => 'fastcloud://$id',
      ),
    );

    if (stream == null) return [];

    return [
      CloudStreamExtractorLink(
        source: name,
        name: '${stream.quality.isNotEmpty ? stream.quality : "720p"} Fast CDN',
        url: stream.url,
        referer: stream.headers['Referer'] ?? '',
        quality: stream.quality.isNotEmpty ? stream.quality : '720p',
        isM3u8: stream.isHls,
        headers: stream.headers,
        subtitles: stream.subtitles,
        qualities: stream.qualities,
      ),
    ];
  }
}
