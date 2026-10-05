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
  }) =>
      _builder(tmdbId, type, season, episode);
}

class StreamServers {
  StreamServers._();

  static final List<StreamServer> all = [
    StreamServer(
      id: 'vidlink',
      name: 'Server 1',
      quality: '4K / HD',
      host: 'vidlink.pro',
      builder: (id, type, s, e) => type == MediaType.movie
          ? 'https://vidlink.pro/movie/$id?primaryColor=fb2c36&secondaryColor=fb2c36'
          : 'https://vidlink.pro/tv/$id/$s/$e?primaryColor=fb2c36&secondaryColor=fb2c36',
    ),
    StreamServer(
      id: 'vidfast',
      name: 'Server 2',
      quality: '1080p / Auto',
      host: 'vidfast.vc',
      builder: (id, type, s, e) => type == MediaType.movie
          ? 'https://vidfast.vc/movie/$id?autoPlay=true'
          : 'https://vidfast.vc/tv/$id/$s/$e?autoPlay=true&theme=fb2c36',
    ),
    StreamServer(
      id: 'vidking',
      name: 'Server 3',
      quality: '4K / Auto',
      host: 'vidking.net',
      builder: (id, type, s, e) => type == MediaType.movie
          ? 'https://www.vidking.net/embed/movie/$id?color=fb2c36'
          : 'https://www.vidking.net/embed/tv/$id/$s/$e?color=fb2c36',
    ),
    StreamServer(
      id: 'vidsrc-tw',
      name: 'Server 4',
      quality: 'Fast Stream',
      host: 'vidsrc.tw',
      builder: (id, type, s, e) => type == MediaType.movie
          ? 'https://vidsrc.tw/embed/movie/$id'
          : 'https://vidsrc.tw/embed/tv/$id/$s/$e',
    ),
    StreamServer(
      id: '1embed',
      name: 'Server 5',
      quality: 'Fast',
      host: '1embed.cc',
      builder: (id, type, s, e) => type == MediaType.movie
          ? 'https://1embed.cc/embed/movie/$id?autoplay=1'
          : 'https://1embed.cc/embed/tv/$id/$s/$e?autoplay=1',
    ),
    StreamServer(
      id: 'vidcore',
      name: 'Server 6',
      quality: 'Fast',
      host: 'vidcore.org',
      builder: (id, type, s, e) => type == MediaType.movie
          ? 'https://vidcore.org/embed/movie/$id'
          : 'https://vidcore.org/embed/series/$id/$s/$e',
    ),
    StreamServer(
      id: '2embed',
      name: 'Server 7',
      quality: 'Multi-Lang',
      host: '2embed.cc',
      builder: (id, type, s, e) => type == MediaType.movie
          ? 'https://www.2embed.cc/embed/$id'
          : 'https://www.2embed.cc/embedtv/$id&s=$s&e=$e',
    ),
  ];

  static StreamServer byId(String id) =>
      all.firstWhere((s) => s.id == id, orElse: () => all.first);
}
