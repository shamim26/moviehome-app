import 'package:flutter_application_1/models/media_item.dart';
import '../../moviebox/moviebox_service.dart';
import '../core/main_api.dart';
import '../models/cloudstream_models.dart';
import 'package:flutter_application_1/models/stream_server.dart';

/// CloudStream provider for MovieBox / SuperStream.
class MovieBoxProvider extends MainAPI {
  @override
  String get id => 'moviebox';

  @override
  String get name => 'MovieBox';

  @override
  String get qualityBadge => 'Fallback / DASH (Low Speed)';

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
        builder: (id, t, s, e) => 'moviebox://$id',
      ),
    );

    if (stream == null) return [];

    return [
      CloudStreamExtractorLink(
        source: name,
        name: '${stream.quality.isNotEmpty ? stream.quality : "HD"} Direct',
        url: stream.url,
        referer: stream.headers['Referer'] ?? '',
        quality: stream.quality.isNotEmpty ? stream.quality : '1080p',
        isM3u8: stream.isHls,
        isDash: stream.url.contains('.mpd'),
        headers: stream.headers,
        subtitles: stream.subtitles,
        qualities: stream.qualities,
      ),
    ];
  }
}
