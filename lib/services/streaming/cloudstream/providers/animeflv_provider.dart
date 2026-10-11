import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../../../../models/extracted_stream.dart';
import '../../../../models/media_item.dart';
import '../core/main_api.dart';
import '../models/cloudstream_models.dart';

/// Independent CloudStream provider for AnimeFLV (animeflv.net).
/// Ported from CloudStream's AnimeFlvProvider.
class AnimeFlvProvider extends MainAPI {
  @override
  String get id => 'animeflv';

  @override
  String get name => 'AnimeFLV';

  @override
  String get qualityBadge => 'Latino/Sub Anime HD (AnimeFLV)';

  @override
  String get mainUrl => 'https://animeflv.net';

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
    'Referer': 'https://animeflv.net/',
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

      debugPrint('[AnimeFlvProvider] Searching for "$cleanTitle" (episode: $episode)');

      // 1. Search AnimeFLV
      final searchUri = Uri.parse('$mainUrl/browse?q=${Uri.encodeComponent(cleanTitle)}');
      final searchRes = await http.get(searchUri, headers: _headers).timeout(const Duration(seconds: 5));
      if (searchRes.statusCode != 200) {
        debugPrint('[AnimeFlvProvider] Search returned HTTP ${searchRes.statusCode}');
        return [];
      }

      final doc = html_parser.parse(searchRes.body);
      final animeCards = doc.querySelectorAll('.Anime, .ListAnimes li, article');
      if (animeCards.isEmpty) {
        debugPrint('[AnimeFlvProvider] No anime cards found');
        return [];
      }

      String? animeSlug;
      for (final card in animeCards) {
        final aTag = card.querySelector('a');
        final href = aTag?.attributes['href'] ?? '';
        final aTitle = card.querySelector('.Title')?.text.trim().toLowerCase() ?? '';

        if (href.startsWith('/anime/')) {
          animeSlug = href.replaceFirst('/anime/', '');
          if (aTitle.contains(cleanTitle.toLowerCase())) {
            break;
          }
        }
      }

      animeSlug ??= animeCards.firstOrNull?.querySelector('a[href^="/anime/"]')?.attributes['href']?.replaceFirst('/anime/', '');
      if (animeSlug == null) {
        debugPrint('[AnimeFlvProvider] Could not find anime slug');
        return [];
      }

      debugPrint('[AnimeFlvProvider] Found anime slug: $animeSlug');

      // 2. Fetch episode page directly
      final epUrl = '$mainUrl/ver/$animeSlug-$episode';
      debugPrint('[AnimeFlvProvider] Fetching episode page: $epUrl');
      final epRes = await http.get(Uri.parse(epUrl), headers: _headers).timeout(const Duration(seconds: 5));
      if (epRes.statusCode != 200) {
        debugPrint('[AnimeFlvProvider] Episode page returned HTTP ${epRes.statusCode}');
        return [];
      }

      // 3. Extract var videos script
      final videoMatch = RegExp(r'var\s+videos\s*=\s*(\{.*?\});').firstMatch(epRes.body);
      if (videoMatch == null) {
        debugPrint('[AnimeFlvProvider] var videos not found in HTML');
        return [];
      }

      final rawVideosJson = videoMatch.group(1);
      if (rawVideosJson == null) return [];

      final videosData = jsonDecode(rawVideosJson) as Map<String, dynamic>;
      final subList = (videosData['SUB'] as List?) ?? [];

      for (final s in subList) {
        final serverName = (s['server'] ?? s['title'])?.toString().toLowerCase() ?? '';
        final code = s['code']?.toString() ?? '';

        debugPrint('[AnimeFlvProvider] Evaluating server: $serverName -> $code');

        // Extract StreamWish
        if (serverName.contains('streamwish') || code.contains('streamwish') || code.contains('wishembed')) {
          final link = await _extractStreamWish(code);
          if (link != null) return [link];
        }

        // Extract YourUpload
        if (serverName.contains('yourupload') || code.contains('yourupload')) {
          final link = await _extractYourUpload(code);
          if (link != null) return [link];
        }

        // Direct stream if code is already a media URL
        if (code.startsWith('http') && (code.contains('.m3u8') || code.contains('.mp4'))) {
          return [
            CloudStreamExtractorLink(
              source: name,
              name: 'AnimeFLV Direct (${serverName.toUpperCase()})',
              url: code,
              referer: mainUrl,
              quality: '720p',
              isM3u8: code.contains('.m3u8'),
              headers: {'Referer': mainUrl},
            ),
          ];
        }
      }
    } catch (e, st) {
      debugPrint('[AnimeFlvProvider] loadLinks error: $e\n$st');
    }
    return [];
  }

  Future<CloudStreamExtractorLink?> _extractStreamWish(String embedUrl) async {
    try {
      final res = await http.get(Uri.parse(embedUrl), headers: _headers).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final m3u8Match = RegExp(r"""(https?://[^\s"'<>]+\.m3u8[^\s"'<>]*)""").firstMatch(res.body);
        if (m3u8Match != null) {
          final streamUrl = m3u8Match.group(1)!;
          return CloudStreamExtractorLink(
            source: name,
            name: 'StreamWish HD (HLS)',
            url: streamUrl,
            referer: embedUrl,
            quality: '1080p',
            isM3u8: true,
            headers: {'Referer': embedUrl},
            qualities: [
              StreamQuality(label: '1080p', url: streamUrl),
              StreamQuality(label: '720p', url: streamUrl),
            ],
          );
        }
      }
    } catch (_) {}
    return null;
  }

  Future<CloudStreamExtractorLink?> _extractYourUpload(String embedUrl) async {
    try {
      final res = await http.get(Uri.parse(embedUrl), headers: _headers).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final mp4Match = RegExp(r"""(https?://[^\s"'<>]+\.mp4[^\s"'<>]*)""").firstMatch(res.body);
        if (mp4Match != null) {
          final streamUrl = mp4Match.group(1)!;
          return CloudStreamExtractorLink(
            source: name,
            name: 'YourUpload Direct (MP4)',
            url: streamUrl,
            referer: embedUrl,
            quality: '720p',
            isM3u8: false,
            headers: {'Referer': embedUrl},
          );
        }
      }
    } catch (_) {}
    return null;
  }
}
