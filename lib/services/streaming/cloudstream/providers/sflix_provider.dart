import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../../../../models/extracted_stream.dart';
import '../../../../models/media_item.dart';
import '../core/main_api.dart';
import '../models/cloudstream_models.dart';

/// Independent CloudStream provider for SFlix (sflix.to / sflix.is).
/// Ported from CloudStream's SflixProvider.
class SflixProvider extends MainAPI {
  @override
  String get id => 'sflix';

  @override
  String get name => 'SFlix';

  @override
  String get qualityBadge => 'Fast HD / Multi-Sub (SFlix)';

  @override
  String get mainUrl => 'https://sflix.to';

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
    'X-Requested-With': 'XMLHttpRequest',
    'Referer': 'https://sflix.to/',
  };

  @override
  Future<List<CloudStreamExtractorLink>> loadLinks({
    required int tmdbId,
    required String title,
    int? year,
    required MediaType type,
    int season = 1,
    int episode = 1,
  }) async {
    try {
      final cleanTitle = title
          .replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ')
          .replaceAll(RegExp(r'[^\w\s]'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      debugPrint('[SflixProvider] Searching for "$cleanTitle" (year: $year, S:$season E:$episode)');

      // 1. Search SFlix
      final searchUri = Uri.parse('$mainUrl/search/${Uri.encodeComponent(cleanTitle)}');
      final searchRes = await http.get(searchUri, headers: _headers).timeout(const Duration(seconds: 5));
      if (searchRes.statusCode != 200) {
        debugPrint('[SflixProvider] Search returned HTTP ${searchRes.statusCode}');
        return [];
      }

      final doc = html_parser.parse(searchRes.body);
      final items = doc.querySelectorAll('.flw-item');
      if (items.isEmpty) {
        debugPrint('[SflixProvider] No items found in search');
        return [];
      }

      String? targetMediaId;
      for (final item in items) {
        final linkTag = item.querySelector('.film-name a');
        final itemTitle = linkTag?.text.trim().toLowerCase() ?? '';
        final href = linkTag?.attributes['href'] ?? '';
        final isTv = href.contains('/tv/');
        final matchesType = (type == MediaType.tv && isTv) || (type == MediaType.movie && !isTv);

        if (matchesType && itemTitle.contains(cleanTitle.toLowerCase())) {
          // Extract data-id or movie slug id
          final parts = href.split('-');
          targetMediaId = parts.isNotEmpty ? parts.last : null;
          break;
        }
      }

      targetMediaId ??= items.first.querySelector('.film-name a')?.attributes['href']?.split('-').last;
      if (targetMediaId == null) {
        debugPrint('[SflixProvider] Could not find media ID');
        return [];
      }

      debugPrint('[SflixProvider] Found media ID: $targetMediaId');

      // 2. Fetch episode ID
      String? episodeId;
      if (type == MediaType.movie) {
        final epRes = await http
            .get(Uri.parse('$mainUrl/ajax/movie/episodes/$targetMediaId'), headers: _headers)
            .timeout(const Duration(seconds: 5));
        if (epRes.statusCode == 200) {
          final epDoc = html_parser.parse(epRes.body);
          final epTag = epDoc.querySelector('.eps-item, [data-id]');
          episodeId = epTag?.attributes['data-id'];
        }
      } else {
        // Fetch seasons
        final seasonRes = await http
            .get(Uri.parse('$mainUrl/ajax/v2/tv/seasons/$targetMediaId'), headers: _headers)
            .timeout(const Duration(seconds: 5));
        if (seasonRes.statusCode == 200) {
          final sDoc = html_parser.parse(seasonRes.body);
          final seasonTags = sDoc.querySelectorAll('[data-id]');
          final targetSeasonTag = seasonTags.length >= season ? seasonTags[season - 1] : seasonTags.firstOrNull;
          final seasonId = targetSeasonTag?.attributes['data-id'];

          if (seasonId != null) {
            final epListRes = await http
                .get(Uri.parse('$mainUrl/ajax/v2/season/episodes/$seasonId'), headers: _headers)
                .timeout(const Duration(seconds: 5));
            if (epListRes.statusCode == 200) {
              final epDoc = html_parser.parse(epListRes.body);
              final epTags = epDoc.querySelectorAll('.eps-item, [data-id]');
              final targetEpTag = epTags.length >= episode ? epTags[episode - 1] : epTags.firstOrNull;
              episodeId = targetEpTag?.attributes['data-id'];
            }
          }
        }
      }

      episodeId ??= targetMediaId;
      debugPrint('[SflixProvider] Resolved episode ID: $episodeId');

      // 3. Fetch server sources
      final serverRes = await http
          .get(Uri.parse('$mainUrl/ajax/episode/servers/$episodeId'), headers: _headers)
          .timeout(const Duration(seconds: 5));
      if (serverRes.statusCode != 200) return [];

      final serverDoc = html_parser.parse(serverRes.body);
      final serverElements = serverDoc.querySelectorAll('[data-id]');
      if (serverElements.isEmpty) return [];

      for (final sElem in serverElements) {
        final sId = sElem.attributes['data-id'];
        if (sId == null) continue;

        final sourceRes = await http
            .get(Uri.parse('$mainUrl/ajax/sources/$sId'), headers: _headers)
            .timeout(const Duration(seconds: 5));
        if (sourceRes.statusCode != 200) continue;

        final sourceJson = jsonDecode(sourceRes.body) as Map<String, dynamic>;
        final embedUrl = sourceJson['link']?.toString() ?? '';
        if (embedUrl.isEmpty) continue;

        debugPrint('[SflixProvider] Extracted embed URL: $embedUrl');

        // Extract stream from embed (MegaCloud / RabbitStream / UpCloud)
        final link = await _extractEmbedSources(embedUrl);
        if (link != null) {
          return [link];
        }
      }
    } catch (e, st) {
      debugPrint('[SflixProvider] loadLinks error: $e\n$st');
    }
    return [];
  }

  Future<CloudStreamExtractorLink?> _extractEmbedSources(String embedUrl) async {
    try {
      final uri = Uri.parse(embedUrl);
      final id = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : null;
      if (id == null) return null;

      final apiUrl = '${uri.scheme}://${uri.host}/embed-2/ajax/e-1/getSources?id=$id';
      final res = await http.get(Uri.parse(apiUrl), headers: {
        'User-Agent': _headers['User-Agent']!,
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': embedUrl,
      }).timeout(const Duration(seconds: 8));

      if (res.statusCode == 200) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        final sources = (json['sources'] as List?) ?? [];
        final tracks = (json['tracks'] as List?) ?? [];

        final subtitles = <SubtitleTrack>[];
        for (final t in tracks) {
          final file = t['file']?.toString() ?? '';
          final label = (t['label'] ?? t['kind'])?.toString().trim() ?? 'Subtitles';
          if (file.startsWith('http')) {
            subtitles.add(SubtitleTrack(
              url: file,
              label: label,
              language: label.toLowerCase().contains('english') ? 'en' : 'und',
            ));
          }
        }

        for (final s in sources) {
          final fileUrl = s['file']?.toString() ?? '';
          if (fileUrl.startsWith('http')) {
            final isM3u8 = fileUrl.contains('.m3u8');
            return CloudStreamExtractorLink(
              source: name,
              name: 'SFlix Auto (HLS)',
              url: fileUrl,
              referer: embedUrl,
              quality: '1080p',
              isM3u8: isM3u8,
              headers: {
                'Referer': embedUrl,
                'User-Agent': _headers['User-Agent']!,
              },
              subtitles: subtitles,
              qualities: [
                StreamQuality(label: '1080p', url: fileUrl),
                StreamQuality(label: '720p', url: fileUrl),
                StreamQuality(label: '480p', url: fileUrl),
              ],
            );
          }
        }
      }
    } catch (e) {
      debugPrint('[SflixProvider] Embed extract error: $e');
    }
    return null;
  }
}
