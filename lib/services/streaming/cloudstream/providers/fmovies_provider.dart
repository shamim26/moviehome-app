import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../../../../models/media_item.dart';
import '../core/main_api.dart';
import '../models/cloudstream_models.dart';

/// Independent CloudStream provider for FMovies (fmovies-online.net / fmoviesto.cc).
/// Ported from CloudStream's FmoviesProvider.
class FmoviesProvider extends MainAPI {
  @override
  String get id => 'fmovies';

  @override
  String get name => 'FMovies';

  @override
  String get qualityBadge => 'Fast HD / Multi-Res (FMovies)';

  @override
  String get mainUrl => 'https://fmovies-online.net';

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
    'Referer': 'https://fmovies-online.net/',
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

      debugPrint('[FmoviesProvider] Searching for "$cleanTitle" (year: $year)');

      // 1. Search FMovies
      final searchUri = Uri.parse('$mainUrl/search/${Uri.encodeComponent(cleanTitle)}');
      final searchRes = await http.get(searchUri, headers: _headers).timeout(const Duration(seconds: 5));
      if (searchRes.statusCode != 200) {
        debugPrint('[FmoviesProvider] Search returned HTTP ${searchRes.statusCode}');
        return [];
      }

      final doc = html_parser.parse(searchRes.body);
      final cards = doc.querySelectorAll('.item, .flw-item, article');
      if (cards.isEmpty) {
        debugPrint('[FmoviesProvider] No cards found in search');
        return [];
      }

      String? watchUrl;
      for (final card in cards) {
        final aTag = card.querySelector('a');
        final href = aTag?.attributes['href'] ?? '';
        final cTitle = (card.querySelector('.title, .film-name')?.text ?? aTag?.text)?.trim().toLowerCase() ?? '';

        if (cTitle.contains(cleanTitle.toLowerCase())) {
          watchUrl = href.startsWith('http') ? href : '$mainUrl$href';
          break;
        }
      }

      watchUrl ??= cards.firstOrNull?.querySelector('a')?.attributes['href'];
      if (watchUrl != null && !watchUrl.startsWith('http')) {
        watchUrl = '$mainUrl$watchUrl';
      }

      if (watchUrl == null) {
        debugPrint('[FmoviesProvider] Could not find watch URL');
        return [];
      }

      debugPrint('[FmoviesProvider] Fetching watch page: $watchUrl');

      // 2. Fetch watch page
      final watchRes = await http.get(Uri.parse(watchUrl), headers: _headers).timeout(const Duration(seconds: 5));
      if (watchRes.statusCode != 200) return [];

      // 3. Extract iframe or direct stream
      final wDoc = html_parser.parse(watchRes.body);
      final iframes = wDoc.querySelectorAll('iframe');

      for (final iframe in iframes) {
        final src = iframe.attributes['src'] ?? iframe.attributes['data-src'] ?? '';
        if (src.isEmpty) continue;

        final fullEmbed = src.startsWith('http') ? src : 'https:$src';
        debugPrint('[FmoviesProvider] Found iframe embed: $fullEmbed');

        final link = await _extractIframe(fullEmbed);
        if (link != null) return [link];
      }

      // Direct video tag or m3u8 pattern
      final m3u8Match = RegExp(r"""(https?://[^\s"'<>]+\.(?:m3u8|mp4)[^\s"'<>]*)""").firstMatch(watchRes.body);
      if (m3u8Match != null) {
        final sUrl = m3u8Match.group(1)!;
        return [
          CloudStreamExtractorLink(
            source: name,
            name: 'FMovies Direct HD',
            url: sUrl,
            referer: watchUrl,
            quality: '1080p',
            isM3u8: sUrl.contains('.m3u8'),
            headers: {'Referer': watchUrl},
          ),
        ];
      }
    } catch (e, st) {
      debugPrint('[FmoviesProvider] loadLinks error: $e\n$st');
    }
    return [];
  }

  Future<CloudStreamExtractorLink?> _extractIframe(String embedUrl) async {
    try {
      final res = await http.get(Uri.parse(embedUrl), headers: {
        'User-Agent': _headers['User-Agent']!,
        'Referer': mainUrl,
      }).timeout(const Duration(seconds: 8));

      if (res.statusCode == 200) {
        final streamMatch = RegExp(r"""(https?://[^\s"'<>]+\.(?:m3u8|mp4)[^\s"'<>]*)""").firstMatch(res.body);
        if (streamMatch != null) {
          final streamUrl = streamMatch.group(1)!;
          return CloudStreamExtractorLink(
            source: name,
            name: 'FMovies Player (HLS)',
            url: streamUrl,
            referer: embedUrl,
            quality: '1080p',
            isM3u8: streamUrl.contains('.m3u8'),
            headers: {'Referer': embedUrl},
          );
        }
      }
    } catch (_) {}
    return null;
  }
}
