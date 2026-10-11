import 'package:flutter_application_1/models/media_item.dart';
import '../../fourkhdhub/fourkhdhub_service.dart';
import '../core/main_api.dart';
import '../models/cloudstream_models.dart';
import 'package:flutter_application_1/models/stream_server.dart';

/// CloudStream provider for HDHub4u / FastCloud.
/// Ported from recloudstream/HindiProviders HDHub4uProvider.
class HDHub4uProvider extends MainAPI {
  @override
  String get id => 'hdhub4u';

  @override
  String get name => 'HDHub4u';

  @override
  String get qualityBadge => 'Fast Edge CDN / 1080p';

  @override
  String get mainUrl => 'https://hdhub4u.tv';

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
      preferredResolution: 1080,
      candidateOffset: 0,
      server: StreamServer(
        id: id,
        name: name,
        quality: qualityBadge,
        host: 'hdhub4u.tv',
        builder: (id, t, s, e) => 'hdhub4u://$id',
      ),
    );

    if (stream == null) return [];

    return [
      CloudStreamExtractorLink(
        source: name,
        name: '${stream.quality.isNotEmpty ? stream.quality : "1080p"} Direct',
        url: stream.url,
        referer: stream.headers['Referer'] ?? '',
        quality: stream.quality.isNotEmpty ? stream.quality : '1080p',
        isM3u8: stream.isHls,
        headers: stream.headers,
        subtitles: stream.subtitles,
        qualities: stream.qualities,
      ),
    ];
  }
}
