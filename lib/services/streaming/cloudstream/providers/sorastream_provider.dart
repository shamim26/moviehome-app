import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../../models/extracted_stream.dart';
import '../../../../models/media_item.dart';
import '../core/main_api.dart';
import '../models/cloudstream_models.dart';

/// Independent CloudStream provider for SoraStream.
/// Ported from CloudStream's SorastreamProvider (Hexated / Stormunblessed).
/// High-speed multi-source aggregator utilizing direct TMDB metadata endpoints.
class SorastreamProvider extends MainAPI {
  @override
  String get id => 'sorastream';

  @override
  String get name => 'SoraStream';

  @override
  String get qualityBadge => 'Multi-Source Ultra HD (SoraStream)';

  @override
  String get mainUrl => 'https://embed.su';

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
    'Referer': 'https://embed.su/',
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
    final links = <CloudStreamExtractorLink>[];

    try {
      debugPrint('[SorastreamProvider] Resolving "$title" (tmdb: $tmdbId, S:$season E:$episode)');

      // 1. Try Embed.su direct backend
      final embedUrl = type == MediaType.movie
          ? 'https://embed.su/embed/movie/$tmdbId'
          : 'https://embed.su/embed/tv/$tmdbId/$season/$episode';

      final embedSuLink = await _resolveEmbedSu(embedUrl, tmdbId: tmdbId, type: type, season: season, episode: episode);
      if (embedSuLink != null) {
        links.add(embedSuLink);
      }

      // 2. Try VidSrc backend
      if (links.isEmpty) {
        final vidsrcUrl = type == MediaType.movie
            ? 'https://vidsrc.cc/v2/embed/movie/$tmdbId'
            : 'https://vidsrc.cc/v2/embed/tv/$tmdbId/$season/$episode';

        final vidsrcLink = await _resolveVidSrc(vidsrcUrl);
        if (vidsrcLink != null) {
          links.add(vidsrcLink);
        }
      }

      // 3. Try AutoEmbed backend
      if (links.isEmpty) {
        final autoUrl = type == MediaType.movie
            ? 'https://player.autoembed.cc/embed/movie/$tmdbId'
            : 'https://player.autoembed.cc/embed/tv/$tmdbId/$season/$episode';

        final autoLink = await _resolveAutoEmbed(autoUrl);
        if (autoLink != null) {
          links.add(autoLink);
        }
      }
    } catch (e, st) {
      debugPrint('[SorastreamProvider] Error loading links: $e\n$st');
    }

    return links;
  }

  Future<CloudStreamExtractorLink?> _resolveEmbedSu(
    String embedUrl, {
    required int tmdbId,
    required MediaType type,
    required int season,
    required int episode,
  }) async {
    try {
      final res = await http.get(Uri.parse(embedUrl), headers: _headers).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        // Extract stream or hash from HTML
        final hashMatch = RegExp(r'''["']hash["']:\s*["']([^"']+)["']''').firstMatch(res.body);
        if (hashMatch != null) {
          final hash = hashMatch.group(1)!;
          final apiUri = Uri.parse('https://embed.su/api/e/$hash');
          final apiRes = await http.get(apiUri, headers: _headers).timeout(const Duration(seconds: 6));
          if (apiRes.statusCode == 200) {
            final json = jsonDecode(apiRes.body) as Map<String, dynamic>;
            final source = json['source']?.toString();
            final tracks = (json['subtitles'] as List?) ?? [];

            final subtitles = <SubtitleTrack>[];
            for (final t in tracks) {
              final file = t['file']?.toString() ?? '';
              final label = (t['label'] ?? t['lang'])?.toString().trim() ?? 'Subtitles';
              if (file.startsWith('http')) {
                subtitles.add(SubtitleTrack(url: file, label: label, language: 'en'));
              }
            }

            if (source != null && source.startsWith('http')) {
              return CloudStreamExtractorLink(
                source: name,
                name: 'SoraStream Ultra HD (HLS)',
                url: source,
                referer: embedUrl,
                quality: '1080p',
                isM3u8: source.contains('.m3u8'),
                headers: {'Referer': embedUrl, 'User-Agent': _headers['User-Agent']!},
                subtitles: subtitles,
              );
            }
          }
        }

        // Direct m3u8 in page
        final m3u8Match = RegExp(r"""(https?://[^\s"'<>]+\.m3u8[^\s"'<>]*)""").firstMatch(res.body);
        if (m3u8Match != null) {
          final url = m3u8Match.group(1)!;
          return CloudStreamExtractorLink(
            source: name,
            name: 'SoraStream Fast HLS',
            url: url,
            referer: embedUrl,
            quality: '1080p',
            isM3u8: true,
            headers: {'Referer': embedUrl},
          );
        }
      }
    } catch (_) {}
    return null;
  }

  Future<CloudStreamExtractorLink?> _resolveVidSrc(String vidsrcUrl) async {
    try {
      final res = await http.get(Uri.parse(vidsrcUrl), headers: _headers).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final streamMatch = RegExp(r"""(https?://[^\s"'<>]+\.(?:m3u8|mp4)[^\s"'<>]*)""").firstMatch(res.body);
        if (streamMatch != null) {
          final url = streamMatch.group(1)!;
          return CloudStreamExtractorLink(
            source: name,
            name: 'SoraStream VidSrc HD',
            url: url,
            referer: vidsrcUrl,
            quality: '1080p',
            isM3u8: url.contains('.m3u8'),
            headers: {'Referer': vidsrcUrl},
          );
        }
      }
    } catch (_) {}
    return null;
  }

  Future<CloudStreamExtractorLink?> _resolveAutoEmbed(String autoUrl) async {
    try {
      final res = await http.get(Uri.parse(autoUrl), headers: _headers).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final streamMatch = RegExp(r"""(https?://[^\s"'<>]+\.(?:m3u8|mp4)[^\s"'<>]*)""").firstMatch(res.body);
        if (streamMatch != null) {
          final url = streamMatch.group(1)!;
          return CloudStreamExtractorLink(
            source: name,
            name: 'SoraStream AutoEmbed HD',
            url: url,
            referer: autoUrl,
            quality: '1080p',
            isM3u8: url.contains('.m3u8'),
            headers: {'Referer': autoUrl},
          );
        }
      }
    } catch (_) {}
    return null;
  }
}
