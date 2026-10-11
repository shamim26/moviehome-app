import 'package:flutter_application_1/models/extracted_stream.dart';
import 'package:flutter_application_1/models/media_item.dart';

/// Models representing CloudStream's core data structures.
/// Ported from https://github.com/recloudstream/cloudstream

/// Represents a media item returned from a search query.
class CloudStreamSearchResponse {
  const CloudStreamSearchResponse({
    required this.id,
    required this.title,
    required this.url,
    required this.type,
    this.posterUrl,
    this.year,
  });

  final String id;
  final String title;
  final String url;
  final MediaType type;
  final String? posterUrl;
  final int? year;
}

/// Represents an episode in a TV series.
class CloudStreamEpisode {
  const CloudStreamEpisode({
    required this.id,
    required this.name,
    required this.season,
    required this.episode,
    required this.data,
    this.url,
  });

  final String id;
  final String name;
  final int season;
  final int episode;
  final String data;
  final String? url;
}

/// Represents a loaded media details response.
class CloudStreamLoadResponse {
  const CloudStreamLoadResponse({
    required this.title,
    required this.url,
    required this.type,
    this.episodes = const [],
    this.plot,
    this.year,
  });

  final String title;
  final String url;
  final MediaType type;
  final List<CloudStreamEpisode> episodes;
  final String? plot;
  final int? year;
}

/// Represents a resolved direct stream link from an extractor.
/// Ported from com.lagradost.cloudstream3.utils.ExtractorLink
class CloudStreamExtractorLink {
  const CloudStreamExtractorLink({
    required this.source,
    required this.name,
    required this.url,
    this.referer = '',
    this.quality = 'Auto',
    this.isM3u8 = false,
    this.isDash = false,
    this.headers = const {},
    this.subtitles = const [],
    this.qualities = const [],
  });

  final String source;
  final String name;
  final String url;
  final String referer;
  final String quality;
  final bool isM3u8;
  final bool isDash;
  final Map<String, String> headers;
  final List<SubtitleTrack> subtitles;
  final List<StreamQuality> qualities;

  Map<String, String> get effectiveHeaders {
    final h = Map<String, String>.from(headers);
    if (referer.isNotEmpty && !h.containsKey('Referer')) {
      h['Referer'] = referer;
    }
    return h;
  }
}
