import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../models/extracted_stream.dart';
import '../../../models/media_item.dart';
import '../../../models/stream_server.dart';

class FourKHdHubService {
  FourKHdHubService._();
  static final FourKHdHubService instance = FourKHdHubService._();

  static const String _baseUrl = 'https://4khdhub.one';
  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
  };

  /// Resolves a playable stream for movie or TV episode using 4KHDHub + HubCloud.
  Future<ExtractedStream?> getStream({
    required String title,
    int? year,
    required MediaType type,
    int season = 1,
    int episode = 1,
    required StreamServer server,
  }) async {
    try {
      final isSeries = type == MediaType.tv;
      debugPrint('[4KHDHub] Searching for "$title" (isSeries: $isSeries, S:$season E:$episode)');

      final searchUri = Uri.parse('$_baseUrl/?s=${Uri.encodeQueryComponent(title)}');
      final searchRes = await http.get(searchUri, headers: _headers).timeout(const Duration(seconds: 12));
      if (searchRes.statusCode != 200) {
        debugPrint('[4KHDHub] Search returned status: ${searchRes.statusCode}');
        return null;
      }

      final cardUrl = _findBestMatchCard(searchRes.body, title: title, year: year, isSeries: isSeries);
      if (cardUrl == null) {
        debugPrint('[4KHDHub] No matching card found for "$title"');
        return null;
      }

      final fullDetailUrl = cardUrl.startsWith('http') ? cardUrl : '$_baseUrl$cardUrl';
      debugPrint('[4KHDHub] Fetching details: $fullDetailUrl');
      final detailRes = await http.get(Uri.parse(fullDetailUrl), headers: _headers).timeout(const Duration(seconds: 12));
      if (detailRes.statusCode != 200) return null;

      final driveCandidates = _extractDriveCandidates(
        detailRes.body,
        isSeries: isSeries,
        season: season,
        episode: episode,
      );

      debugPrint('[4KHDHub] Found ${driveCandidates.length} drive candidate(s)');

      for (final candidate in driveCandidates) {
        final streamUrl = await _resolveDriveLink(candidate.url);
        if (streamUrl != null && streamUrl.isNotEmpty) {
          final cleanUrl = streamUrl.trim().replaceAll(' ', '%20');
          final qualityLabel = '${candidate.resolution}p';
          debugPrint('[4KHDHub] Resolved $qualityLabel stream URL: $cleanUrl');
          return ExtractedStream(
            url: cleanUrl,
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
            },
            server: server,
            quality: qualityLabel,
            qualities: [
              StreamQuality(label: qualityLabel, url: cleanUrl),
            ],
            subtitles: const [],
          );
        }
      }
    } catch (e, st) {
      debugPrint('[4KHDHub] Error resolving stream: $e\n$st');
    }
    return null;
  }

  String? _findBestMatchCard(String html, {required String title, int? year, required bool isSeries}) {
    final cardRegex = RegExp(
      r'<a\s+[^>]*href="([^"]+)"[^>]*class="[^"]*movie-card[^"]*"|<a\s+[^>]*class="[^"]*movie-card[^"]*"[^>]*href="([^"]+)"',
      caseSensitive: false,
    );
    final matches = cardRegex.allMatches(html);

    final cleanTitle = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    String? fallback;
    String? yearMatch;
    String? exactTitleMatch;
    String? partialMatch;

    for (final m in matches) {
      final href = m.group(1) ?? m.group(2);
      if (href == null) continue;

      final isCardSeries = href.contains('-series-');
      if (isSeries && !isCardSeries) continue;
      if (!isSeries && isCardSeries) continue;

      fallback ??= href;

      final hrefLower = href.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      final hasYear = year != null && href.contains('$year');

      // Check if href starts with the title, e.g. /runner-movie-
      final slug = href.toLowerCase().replaceAll(RegExp(r'^/|/$'), '');
      final isExactSlugStart = slug.startsWith('$cleanTitle-') ||
          slug.startsWith('${cleanTitle}movie') ||
          slug.startsWith('${cleanTitle}series');

      if (hasYear && hrefLower.contains(cleanTitle)) {
        yearMatch ??= href;
      }
      if (isExactSlugStart) {
        exactTitleMatch ??= href;
      }
      if (hrefLower.contains(cleanTitle)) {
        partialMatch ??= href;
      }
    }

    return yearMatch ?? exactTitleMatch ?? partialMatch ?? fallback;
  }

  List<_FourKCandidate> _extractDriveCandidates(
    String html, {
    required bool isSeries,
    required int season,
    required int episode,
  }) {
    final candidates = <_FourKCandidate>[];

    if (isSeries) {
      final epRegex = RegExp('S0?${season}E0?$episode', caseSensitive: false);
      final itemBlocks = html.split('class="episode-download-item"');
      for (var i = 1; i < itemBlocks.length; i++) {
        final block = itemBlocks[i];
        if (!epRegex.hasMatch(block)) continue;

        final titleMatch = RegExp(r'<div class="episode-file-title">\s*(.*?)\s*</div>', dotAll: true).firstMatch(block);
        final title = titleMatch?.group(1)?.trim() ?? '';
        final res = _extractResolution(title);
        final lowerTitle = title.toLowerCase();
        final isH264 = lowerTitle.contains('x264') || lowerTitle.contains('h264');
        final isAac = lowerTitle.contains('aac') ||
            lowerTitle.contains('mp3') ||
            lowerTitle.contains('2.0') ||
            lowerTitle.contains('stereo');

        final linkRegex = RegExp(r'href="([^"]*(?:greenmotors|hubcloud|hubdrive)[^"]*)"', caseSensitive: false);
        for (final m in linkRegex.allMatches(block)) {
          final link = m.group(1);
          if (link != null) {
            candidates.add(_FourKCandidate(url: link, title: title, resolution: res, isH264: isH264, isAac: isAac));
          }
        }
      }
    } else {
      final blocks = html.split(RegExp(r'<div class="file-title">', caseSensitive: false));
      for (var i = 1; i < blocks.length; i++) {
        final block = blocks[i];
        final titleEnd = block.indexOf('</div>');
        final title = titleEnd != -1 ? block.substring(0, titleEnd).trim() : '';
        final res = _extractResolution(title);
        final lowerTitle = title.toLowerCase();
        final isH264 = lowerTitle.contains('x264') || lowerTitle.contains('h264');
        final isAac = lowerTitle.contains('aac') ||
            lowerTitle.contains('mp3') ||
            lowerTitle.contains('2.0') ||
            lowerTitle.contains('stereo');

        final linkRegex = RegExp(r'href="([^"]*(?:greenmotors|hubcloud|hubdrive)[^"]*)"', caseSensitive: false);
        for (final m in linkRegex.allMatches(block)) {
          final link = m.group(1);
          if (link != null) {
            candidates.add(_FourKCandidate(url: link, title: title, resolution: res, isH264: isH264, isAac: isAac));
          }
        }
      }
    }

    // Sort to prioritize universally supported mobile resolutions (1080p, 720p)
    // and deprioritize 4K/2160p to prevent ExoPlayer decoder crashing on budget/mid-range chips
    candidates.sort((a, b) {
      int score(_FourKCandidate c) {
        int s = 0;
        // Prioritize universally supported AAC/MP3/Stereo audio
        if (c.isAac) {
          s += 3000;
        }

        if (c.resolution == 1080) {
          s += 1000;
        } else if (c.resolution == 720) {
          s += 800;
        } else if (c.resolution == 480) {
          s += 600;
        } else if (c.resolution == 2160) {
          s += 100; // 4K deprioritized for mobile compatibility
        } else {
          s += 500;
        }

        if (c.url.contains('hubcloud') || c.title.toLowerCase().contains('hubcloud')) {
          s += 50;
        }
        if (c.isH264) {
          s += 20;
        }
        return s;
      }

      return score(b).compareTo(score(a));
    });

    // Remove duplicates by URL while preserving sorted order
    final seen = <String>{};
    return candidates.where((c) => seen.add(c.url)).toList();
  }

  int _extractResolution(String text) {
    // Strip site branding to avoid false positive on "4khdhub"
    final clean = text.toLowerCase().replaceAll('4khdhub', '');
    if (clean.contains('1080p') || clean.contains(RegExp(r'\b1080\b')) || clean.contains(RegExp(r'\bfhd\b'))) {
      return 1080;
    }
    if (clean.contains('720p') || clean.contains(RegExp(r'\b720\b'))) {
      return 720;
    }
    if (clean.contains('480p') || clean.contains(RegExp(r'\b480\b')) || clean.contains(RegExp(r'\bsd\b'))) {
      return 480;
    }
    if (clean.contains('2160p') || clean.contains(RegExp(r'\b4k\b')) || clean.contains(RegExp(r'\buhd\b'))) {
      return 2160;
    }
    return 1080;
  }

  Future<String?> _resolveDriveLink(String driveUrl) async {
    try {
      String hubcloudUrl = driveUrl;

      if (driveUrl.contains('greenmotors.') || driveUrl.contains('greenmountmotors.')) {
        final greenRes = await http.get(Uri.parse(driveUrl), headers: _headers).timeout(const Duration(seconds: 8));
        if (greenRes.statusCode != 200) return null;
        final unpacked = _unpackGreenmotors(greenRes.body);
        if (unpacked == null) return null;
        hubcloudUrl = unpacked;
      }

      if (!hubcloudUrl.contains('hubcloud.')) return null;

      final hcRes = await http.get(Uri.parse(hubcloudUrl), headers: _headers).timeout(const Duration(seconds: 8));
      if (hcRes.statusCode != 200) return null;

      final resolverRegex = RegExp(r'href="([^"]*(?:hubcloud\.php|gamerxyt\.com|download)[^"]*)"', caseSensitive: false);
      final resolverMatch = resolverRegex.firstMatch(hcRes.body);
      if (resolverMatch == null) return null;

      final resolverUrl = resolverMatch.group(1)!;
      final finalResolverUrl = resolverUrl.startsWith('http') ? resolverUrl : 'https://hubcloud.ist$resolverUrl';

      final resolverHeaders = Map<String, String>.from(_headers);
      resolverHeaders['Referer'] = hubcloudUrl;

      final resRes = await http.get(Uri.parse(finalResolverUrl), headers: resolverHeaders).timeout(const Duration(seconds: 10));
      if (resRes.statusCode != 200) return null;

      final candidates = <String>[];

      // 1. Worker or direct mkv/mp4 download
      final directStreamRegex = RegExp(r'href="([^"]*(?:workers\.dev|[^\s"]+\.(?:mkv|mp4))[^\s"]*)"', caseSensitive: false);
      for (final m in directStreamRegex.allMatches(resRes.body)) {
        final url = m.group(1);
        if (url != null && url.startsWith('http')) {
          candidates.add(url);
        }
      }

      // 2. Pixeldrain
      final pdRegex = RegExp(r'https?://(?:pixel\.hubcloud\.ist/\?id=|pixeldrain\.(?:com|dev)/(?:u|api/file)/)([a-zA-Z0-9_\-]+)');
      for (final m in pdRegex.allMatches(resRes.body)) {
        final id = m.group(1);
        if (id != null && !id.contains('pixel.hubcloud.ist')) {
          candidates.add('https://pixeldrain.com/api/file/$id?download');
        }
      }

      for (final candidate in candidates) {
        final decodedLower = Uri.decodeFull(candidate).toLowerCase();
        // Skip 2160p / 4K files on mobile devices where hardware decoder cannot handle 4K (e.g. Snapdragon 685)
        if (decodedLower.contains('2160p') ||
            decodedLower.contains('.4k.') ||
            decodedLower.contains('-4k.') ||
            decodedLower.contains('3840x2160')) {
          debugPrint('[4KHDHub] Skipping 4K/2160p stream for mobile decoder compatibility: $candidate');
          continue;
        }

        if (await _preflightCandidate(candidate)) {
          return candidate;
        }
      }
    } catch (e) {
      debugPrint('[4KHDHub] Error in _resolveDriveLink: $e');
    }
    return null;
  }

  Future<bool> _preflightCandidate(String url) async {
    try {
      final client = http.Client();
      final req = http.Request('GET', Uri.parse(url));
      req.headers['User-Agent'] = _headers['User-Agent']!;
      req.headers['Range'] = 'bytes=0-1024';

      final res = await client.send(req).timeout(const Duration(seconds: 5));
      if (res.statusCode >= 400) {
        debugPrint('[4KHDHub] Candidate rejected: HTTP ${res.statusCode}');
        return false;
      }

      final cType = res.headers['content-type']?.toLowerCase() ?? '';
      if (cType.contains('application/json') || cType.contains('text/html')) {
        final bodyBytes = await res.stream.toBytes();
        final bodyStr = utf8.decode(bodyBytes, allowMalformed: true).toLowerCase();
        if (bodyStr.contains('downloadquotaexceeded') ||
            bodyStr.contains('quota') ||
            bodyStr.contains('expired')) {
          debugPrint('[4KHDHub] Candidate rejected: Quota exceeded / expired');
          return false;
        }
      }
      return true;
    } catch (e) {
      debugPrint('[4KHDHub] Candidate preflight failed: $e');
      return false;
    }
  }

  String? _unpackGreenmotors(String html) {
    final reg = RegExp(r"""s\(\s*['"]o['"]\s*,\s*['"]([^'"]+)['"]""");
    final match = reg.firstMatch(html);
    if (match == null) return null;
    return _decodeGreenmotorsPayload(match.group(1)!);
  }

  String? _decodeGreenmotorsPayload(String payload) {
    try {
      final step1 = utf8.decode(base64.decode(payload));
      final step2 = utf8.decode(base64.decode(step1));
      final step3 = _rot13(step2);
      final step4 = utf8.decode(base64.decode(step3));
      final json = jsonDecode(step4) as Map<String, dynamic>;
      final targetB64 = json['o'] as String;
      return utf8.decode(base64.decode(targetB64));
    } catch (_) {
      return null;
    }
  }

  String _rot13(String input) {
    final out = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      final code = input.codeUnitAt(i);
      if (code >= 65 && code <= 90) {
        out.writeCharCode((code - 65 + 13) % 26 + 65);
      } else if (code >= 97 && code <= 122) {
        out.writeCharCode((code - 97 + 13) % 26 + 97);
      } else {
        out.writeCharCode(code);
      }
    }
    return out.toString();
  }
}

class _FourKCandidate {
  final String url;
  final String title;
  final int resolution;
  final bool isH264;
  final bool isAac;

  const _FourKCandidate({
    required this.url,
    required this.title,
    required this.resolution,
    this.isH264 = false,
    this.isAac = false,
  });
}

