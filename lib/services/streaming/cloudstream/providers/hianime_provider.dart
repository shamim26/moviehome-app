import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../../../../models/extracted_stream.dart';
import '../../../../models/media_item.dart';
import '../core/main_api.dart';
import '../models/cloudstream_models.dart';

/// Independent CloudStream provider for HiAnime (hianime.to, formerly AniWatch / Zoro).
/// Ported from CloudStream's HiAnimeProvider.
class HiAnimeProvider extends MainAPI {
  @override
  String get id => 'hianime';

  @override
  String get name => 'HiAnime';

  @override
  String get qualityBadge => 'Anime HD / Multi-Sub (HiAnime)';

  @override
  String get mainUrl => 'https://hianime.to';

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
    'X-Requested-With': 'XMLHttpRequest',
    'Referer': 'https://hianime.to/',
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

      debugPrint('[HiAnimeProvider] Searching for anime "$cleanTitle" (S:$season E:$episode)');

      // 1. Search anime
      final searchUri = Uri.parse('$mainUrl/search?keyword=${Uri.encodeComponent(cleanTitle)}');
      final searchRes = await http.get(searchUri, headers: _headers).timeout(const Duration(seconds: 5));
      if (searchRes.statusCode != 200) {
        debugPrint('[HiAnimeProvider] Search returned HTTP ${searchRes.statusCode}');
        return [];
      }

      final doc = html_parser.parse(searchRes.body);
      final filmCards = doc.querySelectorAll('.film-detail .film-name a, .film_list-wrap .flw-item a');
      if (filmCards.isEmpty) {
        debugPrint('[HiAnimeProvider] No anime found matching "$cleanTitle"');
        return [];
      }

      String? animeId;
      for (final card in filmCards) {
        final href = card.attributes['href'] ?? '';
        final cTitle = card.text.trim().toLowerCase();
        if (cTitle.contains(cleanTitle.toLowerCase()) || href.contains('watch')) {
          final parts = href.split('-');
          animeId = parts.isNotEmpty ? parts.last.replaceAll(RegExp(r'[^0-9]'), '') : null;
          if (animeId != null && animeId.isNotEmpty) break;
        }
      }

      animeId ??= filmCards.first.attributes['href']?.split('?').first.split('-').last;
      if (animeId == null || animeId.isEmpty) {
        debugPrint('[HiAnimeProvider] Could not parse anime ID');
        return [];
      }

      debugPrint('[HiAnimeProvider] Matched anime ID: $animeId');

      // 2. Fetch episodes list
      final epListUri = Uri.parse('$mainUrl/ajax/v2/episode/list/$animeId');
      final epListRes = await http.get(epListUri, headers: _headers).timeout(const Duration(seconds: 5));
      if (epListRes.statusCode != 200) return [];

      final epListJson = jsonDecode(epListRes.body) as Map<String, dynamic>;
      final htmlSnippet = epListJson['html']?.toString() ?? '';
      final epDoc = html_parser.parse(htmlSnippet);
      final epItems = epDoc.querySelectorAll('.ep-item');

      String? targetEpisodeId;
      for (final epItem in epItems) {
        final epNum = epItem.attributes['data-number'];
        final epId = epItem.attributes['data-id'];
        if (epNum == episode.toString()) {
          targetEpisodeId = epId;
          break;
        }
      }

      targetEpisodeId ??= epItems.firstOrNull?.attributes['data-id'];
      if (targetEpisodeId == null) {
        debugPrint('[HiAnimeProvider] No episode found for episode $episode');
        return [];
      }

      debugPrint('[HiAnimeProvider] Found target episode ID: $targetEpisodeId');

      // 3. Fetch servers
      final serverUri = Uri.parse('$mainUrl/ajax/v2/episode/servers?episodeId=$targetEpisodeId');
      final serverRes = await http.get(serverUri, headers: _headers).timeout(const Duration(seconds: 5));
      if (serverRes.statusCode != 200) return [];

      final serverJson = jsonDecode(serverRes.body) as Map<String, dynamic>;
      final serverHtml = serverJson['html']?.toString() ?? '';
      final sDoc = html_parser.parse(serverHtml);
      final serverElements = sDoc.querySelectorAll('.server-item, [data-id]');

      for (final sElem in serverElements) {
        final sId = sElem.attributes['data-id'];
        if (sId == null) continue;

        // Fetch sources for server
        final sourceUri = Uri.parse('$mainUrl/ajax/v2/episode/sources?id=$sId');
        final sourceRes = await http.get(sourceUri, headers: _headers).timeout(const Duration(seconds: 5));
        if (sourceRes.statusCode != 200) continue;

        final sourceJson = jsonDecode(sourceRes.body) as Map<String, dynamic>;
        final embedLink = sourceJson['link']?.toString() ?? '';
        if (embedLink.isEmpty) continue;

        debugPrint('[HiAnimeProvider] Resolved embed: $embedLink');

        final link = await _extractMegaCloudSources(embedLink);
        if (link != null) {
          return [link];
        }
      }
    } catch (e, st) {
      debugPrint('[HiAnimeProvider] loadLinks error: $e\n$st');
    }
    return [];
  }

  Future<CloudStreamExtractorLink?> _extractMegaCloudSources(String embedUrl) async {
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
              name: 'HiAnime HD (HLS)',
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
      debugPrint('[HiAnimeProvider] Embed extraction error: $e');
    }
    return null;
  }
}
