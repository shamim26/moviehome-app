import 'package:flutter/foundation.dart';

import 'package:flutter_application_1/models/extracted_stream.dart';
import 'package:flutter_application_1/models/media_item.dart';
import 'package:flutter_application_1/models/stream_server.dart';
import '../../subtitles/subtitle_resolver.dart';
import '../providers/animeflv_provider.dart';
import '../providers/fastcloud_provider.dart';
import '../providers/fmovies_provider.dart';
import '../providers/fourkhdhub_provider.dart';
import '../providers/hdhub4u_provider.dart';
import '../providers/hianime_provider.dart';
import '../providers/moviebox_provider.dart';
import '../providers/sflix_provider.dart';
import '../providers/sorastream_provider.dart';
import '../providers/superstream_mirror_provider.dart';
import 'main_api.dart';

/// Represents a repository containing multiple CloudStream providers.
/// Ported from CloudStream's Repository manifest.
class CloudStreamRepo {
  const CloudStreamRepo({
    required this.id,
    required this.name,
    required this.description,
    required this.providers,
  });

  final String id;
  final String name;
  final String description;
  final List<MainAPI> providers;
}

/// Central repository and plugin manager for CloudStream mechanism.
/// All default servers are pre-injected and ready from the beginning.
class CloudStreamRepoManager {
  CloudStreamRepoManager._() {
    _initializeDefaultRepos();
  }

  static final CloudStreamRepoManager instance = CloudStreamRepoManager._();

  final List<CloudStreamRepo> _repos = [];
  final Map<String, MainAPI> _providersMap = {};

  List<CloudStreamRepo> get repos => List.unmodifiable(_repos);
  List<MainAPI> get allProviders => List.unmodifiable(_providersMap.values);
  MainAPI? getProvider(String id) => _providersMap[id];

  /// Pre-injects core repositories from the start so servers are ready immediately.
  /// High speed independent providers are placed first.
  /// Slow/buffering DASH servers (MovieBox) are kept in the last section.
  void _initializeDefaultRepos() {
    final coreRepo = CloudStreamRepo(
      id: 'core_repo',
      name: 'Default CloudStream Repository',
      description: 'Pre-injected high speed providers with multi-audio, multi-res, and subs',
      providers: [
        FourKHdHubProvider(), // Server 1 (4KHDHub - Ultra HD 4K / High Speed R2 CDN)
        FastCloudProvider(), // Server 2 (FastCloud - High-Speed Edge CDN / Multi-Audio)
        SuperStreamMirrorProvider(), // Server 3 (SuperStream - Direct MP4 CDN / Multi-Res)
        SorastreamProvider(), // Server 4 (SoraStream - Multi-Source Ultra HD)
        SflixProvider(), // Server 5 (SFlix - Fast HD + Subs)
        FmoviesProvider(), // Server 6 (FMovies - Fast HD + Multi-Res)
        HiAnimeProvider(), // Server 7 (HiAnime - Anime HD + Subs)
        AnimeFlvProvider(), // Server 8 (AnimeFLV - Latino/Sub Anime HD)
        HDHub4uProvider(), // Server 9 (HDHub4u - Fast Edge CDN / 1080p)
        MovieBoxProvider(), // Server 10 (MovieBox - Fallback / DASH - Last section)
      ],
    );

    injectRepo(coreRepo);
  }

  /// Injects a new repository into the manager.
  void injectRepo(CloudStreamRepo repo) {
    _repos.removeWhere((r) => r.id == repo.id);
    _repos.add(repo);

    for (final provider in repo.providers) {
      _providersMap[provider.id] = provider;
    }

    debugPrint('[CloudStreamRepoManager] Injected repo "${repo.name}" with ${repo.providers.length} provider(s)');
  }

  /// Retrieves a provider by ID.
  MainAPI? getProviderById(String id) {
    return _providersMap[id];
  }

  /// Converts all registered providers into [StreamServer] list for the UI.
  List<StreamServer> getStreamServers() {
    final servers = <StreamServer>[];
    for (int i = 0; i < allProviders.length; i++) {
      final p = allProviders[i];
      final serverNum = i + 1;
      servers.add(
        StreamServer(
          id: p.id,
          name: 'Server $serverNum',
          quality: '${p.name} (${p.qualityBadge})',
          host: Uri.tryParse(p.mainUrl)?.host ?? p.id,
          builder: (id, type, s, e) => '${p.id}://$id',
        ),
      );
    }
    return servers;
  }

  /// Resolves a playable [ExtractedStream] for the given TMDB item using CloudStream mechanism.
  Future<ExtractedStream?> resolveStream({
    required String providerId,
    required int tmdbId,
    required String title,
    int? year,
    required MediaType type,
    int season = 1,
    int episode = 1,
    required StreamServer server,
  }) async {
    final provider = getProviderById(providerId) ?? _providersMap.values.first;
    debugPrint('[CloudStreamRepoManager] Loading links via provider [${provider.name}] (${provider.id})');

    try {
      final links = await provider.loadLinks(
        tmdbId: tmdbId,
        title: title,
        year: year,
        type: type,
        season: season,
        episode: episode,
      );

      if (links.isEmpty) {
        debugPrint('[CloudStreamRepoManager] Provider [${provider.name}] returned no links');
        return null;
      }

      // Pick best link (highest quality or first available)
      final primaryLink = links.first;
      debugPrint('[CloudStreamRepoManager] Resolved primary link: ${primaryLink.url}');

      // Consolidate qualities across links
      final allQualities = <StreamQuality>[];
      for (final link in links) {
        if (link.qualities.isNotEmpty) {
          for (final q in link.qualities) {
            if (!allQualities.any((existing) => existing.url == q.url)) {
              allQualities.add(q);
            }
          }
        } else {
          allQualities.add(StreamQuality(
            label: link.quality.isNotEmpty ? link.quality : 'Auto',
            url: link.url,
          ));
        }
      }

      // Consolidate subtitles across links
      final allSubs = <SubtitleTrack>[];
      for (final link in links) {
        for (final sub in link.subtitles) {
          if (!allSubs.any((s) => s.url == sub.url)) {
            allSubs.add(sub);
          }
        }
      }

      // If provider returned no subtitles (e.g. Server 1 4KHDHub, Server 2 FastCloud),
      // resolve comprehensive multilingual subtitles so every server has subtitles.
      if (allSubs.isEmpty) {
        final extSubs = await SubtitleResolver.instance.resolveSubtitles(
          title: title,
          tmdbId: tmdbId,
          year: year,
          type: type,
          season: season,
          episode: episode,
        );
        allSubs.addAll(extSubs);
      }

      return ExtractedStream(
        url: primaryLink.url,
        headers: primaryLink.effectiveHeaders,
        server: server,
        quality: primaryLink.quality,
        qualities: allQualities,
        subtitles: allSubs,
      );
    } catch (e, st) {
      debugPrint('[CloudStreamRepoManager] Error resolving links from [${provider.name}]: $e\n$st');
      return null;
    }
  }
}
