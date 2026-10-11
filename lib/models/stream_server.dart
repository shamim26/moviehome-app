import '../services/streaming/cloudstream/core/repo_manager.dart';
import 'media_item.dart';

/// A streaming server provider in the app.
class StreamServer {
  // ignore: prefer_initializing_formals
  const StreamServer({
    required this.id,
    required this.name,
    required this.quality,
    required this.host,
    required String Function(int id, MediaType type, int season, int episode) builder,
  // ignore: prefer_initializing_formals
  }) : _builder = builder;

  final String id;
  final String name;
  final String quality;

  /// Host the player is allowed to stay on.
  final String host;
  final String Function(int id, MediaType type, int season, int episode)
  _builder;

  String buildUrl(
    int tmdbId,
    MediaType type, {
    int season = 1,
    int episode = 1,
  }) => _builder(tmdbId, type, season, episode);
}

class StreamServers {
  StreamServers._();

  static List<StreamServer> get all {
    final servers = CloudStreamRepoManager.instance.getStreamServers();
    if (servers.isNotEmpty) return servers;

    // Fallback static servers
    return [
      StreamServer(
        id: '4khdhub',
        name: 'Server 1',
        quality: 'Ultra HD 4K / High Speed R2 CDN (4KHDHub)',
        host: '4khdhub.one',
        builder: (id, type, s, e) => '4khdhub://$id',
      ),
      StreamServer(
        id: 'fastcloud',
        name: 'Server 2',
        quality: 'High-Speed Edge CDN / Multi-Audio (FastCloud)',
        host: 'hubcloud.club',
        builder: (id, type, s, e) => 'fastcloud://$id',
      ),
      StreamServer(
        id: 'superstream_fast',
        name: 'Server 3',
        quality: 'Fast CDN / Multi-Res (SuperStream)',
        host: 'api.inmoviebox.com',
        builder: (id, type, s, e) => 'superstream_fast://$id',
      ),
      StreamServer(
        id: 'sorastream',
        name: 'Server 4',
        quality: 'Multi-Source Ultra HD (SoraStream)',
        host: 'embed.su',
        builder: (id, type, s, e) => 'sorastream://$id',
      ),
      StreamServer(
        id: 'sflix',
        name: 'Server 5',
        quality: 'Fast HD / Multi-Sub (SFlix)',
        host: 'sflix.to',
        builder: (id, type, s, e) => 'sflix://$id',
      ),
      StreamServer(
        id: 'fmovies',
        name: 'Server 6',
        quality: 'Fast HD / Multi-Res (FMovies)',
        host: 'fmovies-online.net',
        builder: (id, type, s, e) => 'fmovies://$id',
      ),
      StreamServer(
        id: 'hianime',
        name: 'Server 7',
        quality: 'Anime HD / Multi-Sub (HiAnime)',
        host: 'hianime.to',
        builder: (id, type, s, e) => 'hianime://$id',
      ),
      StreamServer(
        id: 'animeflv',
        name: 'Server 8',
        quality: 'Latino/Sub Anime HD (AnimeFLV)',
        host: 'animeflv.net',
        builder: (id, type, s, e) => 'animeflv://$id',
      ),
      StreamServer(
        id: 'hdhub4u',
        name: 'Server 9',
        quality: 'Fast Edge CDN / 1080p (HDHub4u)',
        host: 'hdhub4u.tv',
        builder: (id, type, s, e) => 'hdhub4u://$id',
      ),
      StreamServer(
        id: 'moviebox',
        name: 'Server 10',
        quality: 'Fallback / DASH - Low Speed (MovieBox)',
        host: 'api.inmoviebox.com',
        builder: (id, type, s, e) => 'moviebox://$id',
      ),
    ];
  }

  static StreamServer byId(String id) =>
      all.firstWhere((s) => s.id == id, orElse: () => all.first);
}
