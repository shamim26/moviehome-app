import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../models/extracted_stream.dart';
import '../../models/media_item.dart';
import '../../models/stream_server.dart';
import 'cloudstream/core/repo_manager.dart';

/// Stream extraction service utilizing CloudStream repository mechanisms.
/// Completely eliminates headless webviews, ad scripts, and malformed MSE blobs.
class StreamExtractor {
  StreamExtractor._();

  static final StreamExtractor instance = StreamExtractor._();

  int _epoch = 0;

  /// Preserved for backwards compatibility with player lifecycle.
  Future<void> disposeAllWebViews() async {
    // No-op: CloudStream mechanism operates 100% natively over HTTP without WebViews.
    debugPrint('[Extractor] CloudStream engine clean - no webviews active');
  }

  /// Cancels any in-flight extraction.
  void cancelAll() {
    _epoch++;
  }

  /// Extracts a stream from a single specific server using the CloudStream repository engine.
  Future<ExtractedStream?> extractSingleServer({
    required StreamServer server,
    required int tmdbId,
    required MediaType type,
    String? title,
    int? year,
    int season = 1,
    int episode = 1,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    return _extractFromServer(
      server,
      tmdbId,
      type,
      title,
      year,
      season,
      episode,
      timeout,
    );
  }

  /// Attempts to extract a direct video stream from a given [StreamServer].
  /// If the server fails or times out, it automatically tries fallback servers from the repository.
  Future<ExtractedStream?> extractStream({
    required int tmdbId,
    required MediaType type,
    StreamServer? server,
    String? title,
    int? year,
    int season = 1,
    int episode = 1,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final myEpoch = _epoch;
    final primaryServer = server ?? StreamServers.all.first;

    // Try primary server first
    final stream = await _extractFromServer(
      primaryServer,
      tmdbId,
      type,
      title,
      year,
      season,
      episode,
      timeout,
    );

    if (stream != null) return stream;

    // Try fallback servers from the CloudStream repository
    final fallbacks = StreamServers.all.where((s) => s.id != primaryServer.id);
    for (final fallback in fallbacks) {
      if (myEpoch != _epoch) return null;
      final fallbackStream = await _extractFromServer(
        fallback,
        tmdbId,
        type,
        title,
        year,
        season,
        episode,
        timeout,
      );
      if (fallbackStream != null) return fallbackStream;
    }

    return null;
  }

  Future<ExtractedStream?> _extractFromServer(
    StreamServer server,
    int tmdbId,
    MediaType type,
    String? title,
    int? year,
    int season,
    int episode,
    Duration timeout,
  ) async {
    final cleanTitle = title?.trim() ?? '';
    if (cleanTitle.isEmpty) {
      debugPrint('[Extractor] Cannot resolve stream without media title');
      return null;
    }

    final myEpoch = _epoch;
    debugPrint('[Extractor] CloudStream resolving [${server.name}] (${server.id}) for "$cleanTitle"');

    try {
      final stream = await CloudStreamRepoManager.instance
          .resolveStream(
            providerId: server.id,
            tmdbId: tmdbId,
            title: cleanTitle,
            year: year,
            type: type,
            season: season,
            episode: episode,
            server: server,
          )
          .timeout(timeout, onTimeout: () => null);

      if (myEpoch != _epoch) {
        debugPrint('[Extractor] Extraction superseded by newer request, discarding');
        return null;
      }

      return stream;
    } catch (e, st) {
      debugPrint('[Extractor] CloudStream resolution error on ${server.name}: $e\n$st');
      return null;
    }
  }
}
