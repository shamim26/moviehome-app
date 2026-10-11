import 'package:flutter_application_1/models/media_item.dart';
import '../../fourkhdhub/fourkhdhub_service.dart';
import '../core/main_api.dart';
import '../models/cloudstream_models.dart';
import 'package:flutter_application_1/models/stream_server.dart';

/// CloudStream provider for 4KHDHub / HubCloud.
class FourKHdHubProvider extends MainAPI {
  @override
  String get id => '4khdhub';

  @override
  String get name => '4KHDHub';

  @override
  String get qualityBadge => 'Ultra HD 4K / CDN (High Bitrate)';

  @override
  String get mainUrl => 'https://4khdhub.one';

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
      server: StreamServer(
        id: id,
        name: name,
        quality: qualityBadge,
        host: '4khdhub.one',
        builder: (id, t, s, e) => '4khdhub://$id',
      ),
    );

    if (stream == null) return [];

    return [
      CloudStreamExtractorLink(
        source: name,
        name: '${stream.quality.isNotEmpty ? stream.quality : "1080p"} CDN',
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
