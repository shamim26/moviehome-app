import 'media_item.dart';

/// A streaming embed provider. Ported from the web app's providers.ts.
class StreamServer {
  const StreamServer({
    required this.id,
    required this.name,
    required this.quality,
    required this.host,
    required String Function(int id, MediaType type, int season, int episode)
    builder,
  }) : _builder = builder; // ignore: prefer_initializing_formals

  final String id;
  final String name;
  final String quality;

  /// Host the player is allowed to stay on (used by the ad blocker).
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

  static final List<StreamServer> all = [
    StreamServer(
      id: 'moviebox',
      name: 'Server 1',
      quality: 'Native HD / 1080p (MovieBox)',
      host: 'api.inmoviebox.com',
      builder: (id, type, s, e) => 'moviebox://$id',
    ),
    StreamServer(
      id: '4khdhub',
      name: 'Server 2',
      quality: 'Ultra HD 4K / CDN (4KHDHub)',
      host: '4khdhub.one',
      builder: (id, type, s, e) => '4khdhub://$id',
    ),
    StreamServer(
      id: 'vidfast',
      name: 'Server 3',
      quality: 'Fast Fallback (vidfast.vc)',
      host: 'vidfast.vc',
      builder: (id, type, s, e) => type == MediaType.movie
          ? 'https://vidfast.vc/movie/$id?autoPlay=true'
          : 'https://vidfast.vc/tv/$id/$s/$e?autoPlay=true',
    ),
  ];

  static StreamServer byId(String id) =>
      all.firstWhere((s) => s.id == id, orElse: () => all.first);
}
