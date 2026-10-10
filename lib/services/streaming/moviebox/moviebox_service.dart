import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

import '../../../models/extracted_stream.dart';
import '../../../models/media_item.dart';
import '../../../models/stream_server.dart';
import 'moviebox_crypto.dart';
import 'moviebox_dash_proxy.dart';
import 'moviebox_session.dart';

class MovieBoxService {
  MovieBoxService._();
  static final MovieBoxService instance = MovieBoxService._();
  factory MovieBoxService() => instance;

  static final Map<String, List<SubtitleTrack>> _subsCache = {};

  static const String baseHost = 'https://api.inmoviebox.com';

  static bool isDeprecationNotice(String url) {
    final lower = url.toLowerCase();
    return lower.contains('b164fbfb4347792950bdfbfb563d39d9') ||
        lower.contains('1c7de0bd3393702d9191801f15f88f8d') ||
        lower.contains('9a0461bc39da389663bf3dbb17091d3f') ||
        lower.contains('/notice.mp4') ||
        (lower.contains('macdn.aoneroom.com') && lower.contains('/other/'));
  }

  static String? resolveDashManifestFromPolicy(String signCookie) {
    if (signCookie.isEmpty) return null;
    for (final part in signCookie.split(';')) {
      final trimmed = part.trim();
      if (trimmed.contains('urlprefix=')) {
        final prefixPart =
            trimmed.substring(trimmed.indexOf('urlprefix=') + 'urlprefix='.length);
        final b64Token = prefixPart.split(':').first.trim();
        var normalized = b64Token.replaceAll('-', '+').replaceAll('_', '/');
        while (normalized.length % 4 != 0) {
          normalized += '=';
        }
        try {
          final decodedBytes = base64Decode(normalized);
          final urlStr = utf8.decode(decodedBytes);
          final base = urlStr.replaceAll(RegExp(r'[\*/]+$'), '');
          if (base.startsWith('http')) {
            return '$base/index.mpd';
          }
        } catch (_) {}
      }
      if (trimmed.startsWith('CloudFront-Policy=')) {
        final policyClean = trimmed.substring('CloudFront-Policy='.length).trim();
        var normalized = policyClean
            .replaceAll('-', '+')
            .replaceAll('_', '=')
            .replaceAll('~', '/');
        while (normalized.length % 4 != 0) {
          normalized += '=';
        }
        try {
          final decodedBytes = base64Decode(normalized);
          final json = jsonDecode(utf8.decode(decodedBytes)) as Map;
          final resource = json['Statement']?[0]?['Resource'] as String?;
          if (resource != null) {
            final base = resource.replaceAll(RegExp(r'[\*/]+$'), '');
            if (base.startsWith('http')) {
              return '$base/index.mpd';
            }
          }
        } catch (_) {}
      }
    }
    return null;
  }

  Future<Map<String, dynamic>?> _request(
    String method,
    String path, {
    Map<String, dynamic>? jsonBody,
  }) async {
    final sessionManager = MovieBoxSessionManager.instance;
    final token = await sessionManager.getToken();
    if (token == null) return null;

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);

    try {
      final url = '$baseHost$path';
      final bodyStr = jsonBody != null ? jsonEncode(jsonBody) : null;

      final headers = MovieBoxCrypto.buildSignedHeaders(
        method: method,
        url: url,
        body: bodyStr,
        authToken: token,
        userAgent: sessionManager.userAgent,
        clientInfo: sessionManager.clientInfo,
        spoofedIp: sessionManager.spoofedIp,
      );

      final req = await client.openUrl(method, Uri.parse(url));
      headers.forEach((k, v) => req.headers.set(k, v));

      if (bodyStr != null) {
        req.write(bodyStr);
      }

      final res = await req.close();
      if (res.statusCode == 401 || res.statusCode == 403) {
        sessionManager.invalidate();
      }

      final text = await res.transform(utf8.decoder).join();
      if (text.isEmpty) return null;
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[MovieBox] request $path error: $e');
      return null;
    } finally {
      client.close();
    }
  }

  Future<ExtractedStream?> getStream({
    required String title,
    int? year,
    required MediaType type,
    int season = 1,
    int episode = 1,
    required StreamServer server,
  }) async {
    debugPrint('[MovieBox] Searching for "$title" (year: $year)...');

    // 1. Search for title
    final cleanKeyword = title
        .replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ')
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final subjectType = type == MediaType.movie ? 1 : 2;

    var searchJson = await _request(
      'POST',
      '/wefeed-mobile-bff/subject-api/search/v2',
      jsonBody: {
        'keyword': cleanKeyword,
        'page': 1,
        'perPage': 15,
        'subjectType': subjectType,
      },
    );

    // Fallback search with simplified title if search returned nothing
    var results = (searchJson?['data']?['results'] as List?) ?? [];
    if (results.isEmpty && cleanKeyword.contains(' ')) {
      final shortKeyword = cleanKeyword.split(' ').take(3).join(' ');
      final retryJson = await _request(
        'POST',
        '/wefeed-mobile-bff/subject-api/search/v2',
        jsonBody: {
          'keyword': shortKeyword,
          'page': 1,
          'perPage': 15,
          'subjectType': subjectType,
        },
      );
      if (retryJson != null && retryJson['code'] == 0) {
        searchJson = retryJson;
        results = (searchJson['data']?['results'] as List?) ?? [];
      }
    }

    if (searchJson == null || searchJson['code'] != 0) {
      debugPrint('[MovieBox] search failed or returned null');
      return null;
    }
    String? matchedSubjectId;
    String? matchedTitle;

    final normTitle = cleanKeyword.toLowerCase();

    for (final res in results) {
      final subjects = (res['subjects'] as List?) ?? [];
      for (final s in subjects) {
        final sTitle = (s['title'] ?? s['name'])?.toString().trim();
        final sId = s['subjectId']?.toString() ?? s['id']?.toString();
        final sYear = s['year']?.toString() ?? s['releaseDate']?.toString();

        if (sId == null || sTitle == null) continue;

        final lowerTitle = sTitle.toLowerCase();
        // Strict original-language check: exclude dubbed versions unless user specifically asked
        final isDubbed = lowerTitle.contains('[hindi]') ||
            lowerTitle.contains('[telugu]') ||
            lowerTitle.contains('[tamil]') ||
            lowerTitle.contains('[dub]') ||
            lowerTitle.contains('[dual]') ||
            lowerTitle.contains('hindi dub');

        if (isDubbed && !normTitle.contains('hindi') && !normTitle.contains('dub')) {
          continue;
        }

        // Compare title match
        final normSubject = sTitle
            .toLowerCase()
            .replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ')
            .replaceAll(RegExp(r'[^\w\s]'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();

        bool isCloseTitle = normSubject == normTitle ||
            normSubject.startsWith(normTitle) ||
            normTitle.startsWith(normSubject) ||
            normSubject.contains(normTitle) ||
            normTitle.contains(normSubject);

        // Check year if available
        bool matchesYear = true;
        if (year != null && sYear != null) {
          matchesYear = sYear.contains(year.toString());
        }

        if (isCloseTitle && matchesYear) {
          matchedSubjectId = sId;
          matchedTitle = sTitle;
          break;
        }
      }
      if (matchedSubjectId != null) break;
    }

    // Fallback: take first non-dubbed subject if exact match wasn't found
    if (matchedSubjectId == null && results.isNotEmpty) {
      for (final res in results) {
        final subjects = (res['subjects'] as List?) ?? [];
        for (final s in subjects) {
          final sTitle = (s['title'] ?? s['name'])?.toString().trim() ?? '';
          final lower = sTitle.toLowerCase();
          final isDubbed = lower.contains('[hindi]') ||
              lower.contains('[telugu]') ||
              lower.contains('[tamil]') ||
              lower.contains('[dub]');
          if (!isDubbed) {
            matchedSubjectId = s['subjectId']?.toString() ?? s['id']?.toString();
            matchedTitle = s['title'] ?? s['name'];
            break;
          }
        }
        if (matchedSubjectId != null) break;
      }
    }

    if (matchedSubjectId == null) {
      debugPrint('[MovieBox] No subject found matching "$title"');
      return null;
    }

    debugPrint('[MovieBox] Matched subject: $matchedTitle (ID: $matchedSubjectId)');

    // 2. Fetch play-info
    final playPath = type == MediaType.movie
        ? '/wefeed-mobile-bff/subject-api/play-info/v2?subjectId=$matchedSubjectId'
        : '/wefeed-mobile-bff/subject-api/play-info/v2?subjectId=$matchedSubjectId&se=$season&ep=$episode';

    final playInfoJson = await _request('GET', playPath);
    if (playInfoJson == null) return null;

    final data = playInfoJson['data'] ?? playInfoJson;
    final streams = (data['streams'] as List?) ?? [];

    String? playUrl;
    Map<String, String> headers = {
      'User-Agent': MovieBoxSessionManager.instance.userAgent,
      'Referer': 'https://sportslive.wine',
    };

    for (final s in streams) {
      final signCookie = s['signCookie']?.toString() ?? '';
      final streamUrl = s['url']?.toString() ?? '';

      // Clean and normalize cookies
      final cleanCookie = signCookie
          .trim()
          .split(';')
          .map((c) => c.trim())
          .where((c) => c.isNotEmpty)
          .join('; ');

      // Try direct stream url if valid (direct streams load much faster than DASH)
      if (streamUrl.startsWith('http') && !isDeprecationNotice(streamUrl)) {
        playUrl = streamUrl;
        if (cleanCookie.isNotEmpty) {
          headers['Cookie'] = cleanCookie;
        }
        break;
      }

      // Try DASH manifest
      final mpd = resolveDashManifestFromPolicy(signCookie);
      if (mpd != null) {
        playUrl = mpd;
        if (cleanCookie.isNotEmpty) {
          headers['Cookie'] = cleanCookie;
        }
        break;
      }
    }

    // 3. Fetch resource list for resourceId (captions) and fallback direct links
    final resPath = type == MediaType.movie
        ? '/wefeed-mobile-bff/subject-api/resource?subjectId=$matchedSubjectId&page=1&perPage=20'
        : '/wefeed-mobile-bff/subject-api/resource?subjectId=$matchedSubjectId&se=$season&ep=$episode&page=1&perPage=20';

    final resJson = await _request('GET', resPath);
    final resList = (resJson?['data']?['list'] as List?) ?? [];

    String? firstResourceId;
    final foundResolutions = <int>{};

    for (final r in resList) {
      firstResourceId ??= (r['id'] ?? r['resourceId'])?.toString();
      final resNum = r['resolution'];
      if (resNum is int && resNum > 0) {
        foundResolutions.add(resNum);
      }
      final link = (r['resourceLink'] ?? r['url'])?.toString() ?? '';
      if (playUrl == null && link.startsWith('http') && !isDeprecationNotice(link)) {
        playUrl = link;
      }
    }

    if (playUrl == null) {
      debugPrint('[MovieBox] No playable stream found for $matchedTitle');
      return null;
    }

    debugPrint('[MovieBox] Found direct playable stream: $playUrl');

    // Parse all available resolutions
    final dispRes = (data['displayResolutions'] ?? '').toString();
    for (final part in dispRes.split(',')) {
      final parsed = int.tryParse(part.trim());
      if (parsed != null && parsed > 0) {
        foundResolutions.add(parsed);
      }
    }
    for (final s in streams) {
      final sRes = (s['resolutions'] ?? '').toString();
      for (final part in sRes.split(',')) {
        final parsed = int.tryParse(part.trim());
        if (parsed != null && parsed > 0) {
          foundResolutions.add(parsed);
        }
      }
    }

    final sortedResolutions = foundResolutions.toList()..sort((a, b) => b.compareTo(a));
    if (sortedResolutions.isEmpty) {
      sortedResolutions.addAll([1080, 720, 480]);
    }

    List<StreamQuality> qualityList = [];
    if (playUrl.contains('.mpd')) {
      final dashInfo = await MovieBoxDashProxy.instance.registerDashStream(
        originalMpdUrl: playUrl,
        headers: headers,
      );
      playUrl = dashInfo.masterUrl;
      qualityList = dashInfo.qualities;
    } else {
      qualityList = sortedResolutions.map((r) {
        return StreamQuality(
          label: '${r}p',
          url: playUrl!,
        );
      }).toList();
    }

    if (qualityList.isEmpty) {
      qualityList.add(StreamQuality(
        label: 'Auto',
        url: playUrl,
      ));
    }

    // 4. Extract external subtitles using get-ext-captions API
    final subtitles = <SubtitleTrack>[];

    if (firstResourceId != null && firstResourceId.isNotEmpty) {
      final capPath =
          '/wefeed-mobile-bff/subject-api/get-ext-captions?subjectId=$matchedSubjectId&resourceId=$firstResourceId';
      final capJson = await _request('GET', capPath);
      final caps = (capJson?['data']?['extCaptions'] ?? capJson?['data']) as List?;
      for (final c in caps ?? []) {
        final subUrl = c['url']?.toString() ?? '';
        final lan = (c['lanName'] ?? c['lan'])?.toString().trim() ?? 'Subtitles';
        final lanCode = (c['lan'] ?? 'en').toString();
        if (subUrl.startsWith('http') && !subtitles.any((s) => s.url == subUrl)) {
          subtitles.add(SubtitleTrack(
            url: subUrl,
            label: lan,
            language: lanCode,
          ));
        }
      }
    }

    // Fallback to captions in play-info if get-ext-captions returned none
    if (subtitles.isEmpty) {
      final captions = (data['extCaptions'] as List?) ?? [];
      for (final c in captions) {
        final subUrl = c['url']?.toString() ?? '';
        final lan = (c['lanName'] ?? c['lan'])?.toString().trim() ?? 'Subtitles';
        final lanCode = (c['lan'] ?? 'en').toString();
        if (subUrl.startsWith('http') && !subtitles.any((s) => s.url == subUrl)) {
          subtitles.add(SubtitleTrack(
            url: subUrl,
            label: lan,
            language: lanCode,
          ));
        }
      }
    }

    // Prioritize English at top if available
    subtitles.sort((a, b) {
      final aEn = a.label.toLowerCase().contains('english');
      final bEn = b.label.toLowerCase().contains('english');
      if (aEn && !bEn) return -1;
      if (!aEn && bEn) return 1;
      return a.label.compareTo(b.label);
    });

    if (subtitles.isNotEmpty) {
      _subsCache['$cleanKeyword-$season-$episode'] = subtitles;
    }

    return ExtractedStream(
      url: playUrl,
      headers: headers,
      server: server,
      quality: qualityList.first.label,
      qualities: qualityList,
      subtitles: subtitles,
    );
  }

  Future<List<SubtitleTrack>> fetchSubtitles({
    required String title,
    int? year,
    required MediaType type,
    int season = 1,
    int episode = 1,
  }) async {
    final cleanKeyword = title
        .replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ')
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final cacheKey = '$cleanKeyword-$season-$episode';
    if (_subsCache.containsKey(cacheKey) && _subsCache[cacheKey]!.isNotEmpty) {
      return _subsCache[cacheKey]!;
    }

    try {
      final subjectType = type == MediaType.movie ? 1 : 2;
      var searchJson = await _request(
        'POST',
        '/wefeed-mobile-bff/subject-api/search/v2',
        jsonBody: {
          'keyword': cleanKeyword,
          'page': 1,
          'perPage': 15,
          'subjectType': subjectType,
        },
      );

      var results = (searchJson?['data']?['results'] as List?) ?? [];
      if (results.isEmpty && cleanKeyword.contains(' ')) {
        final shortKeyword = cleanKeyword.split(' ').take(3).join(' ');
        final retryJson = await _request(
          'POST',
          '/wefeed-mobile-bff/subject-api/search/v2',
          jsonBody: {
            'keyword': shortKeyword,
            'page': 1,
            'perPage': 15,
            'subjectType': subjectType,
          },
        );
        if (retryJson != null && retryJson['code'] == 0) {
          results = (retryJson['data']?['results'] as List?) ?? [];
        }
      }

      if (results.isEmpty) return [];

      String? matchedSubjectId;
      final normTitle = cleanKeyword.toLowerCase();

      for (final res in results) {
        final subjects = (res['subjects'] as List?) ?? [];
        for (final s in subjects) {
          final sTitle = (s['title'] ?? s['name'])?.toString().trim();
          final sId = s['subjectId']?.toString() ?? s['id']?.toString();
          final sYear = s['year']?.toString() ?? s['releaseDate']?.toString();
          if (sId == null || sTitle == null) continue;

          final lowerTitle = sTitle.toLowerCase();
          final isDubbed = lowerTitle.contains('[hindi]') ||
              lowerTitle.contains('[telugu]') ||
              lowerTitle.contains('[tamil]') ||
              lowerTitle.contains('[dub]') ||
              lowerTitle.contains('[dual]') ||
              lowerTitle.contains('hindi dub');
          if (isDubbed && !normTitle.contains('hindi') && !normTitle.contains('dub')) {
            continue;
          }

          final normSubject = sTitle
              .toLowerCase()
              .replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ')
              .replaceAll(RegExp(r'[^\w\s]'), ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();

          bool isCloseTitle = normSubject == normTitle ||
              normSubject.startsWith(normTitle) ||
              normTitle.startsWith(normSubject) ||
              normSubject.contains(normTitle) ||
              normTitle.contains(normSubject);

          bool matchesYear = true;
          if (year != null && sYear != null) {
            matchesYear = sYear.contains(year.toString());
          }

          if (isCloseTitle && matchesYear) {
            matchedSubjectId = sId;
            break;
          }
        }
        if (matchedSubjectId != null) break;
      }

      if (matchedSubjectId == null && results.isNotEmpty) {
        for (final res in results) {
          final subjects = (res['subjects'] as List?) ?? [];
          for (final s in subjects) {
            final sTitle = (s['title'] ?? s['name'])?.toString().trim() ?? '';
            final lower = sTitle.toLowerCase();
            final isDubbed = lower.contains('[hindi]') ||
                lower.contains('[telugu]') ||
                lower.contains('[tamil]') ||
                lower.contains('[dub]');
            if (!isDubbed) {
              matchedSubjectId = s['subjectId']?.toString() ?? s['id']?.toString();
              break;
            }
          }
          if (matchedSubjectId != null) break;
        }
      }

      if (matchedSubjectId == null) return [];

      final resPath = type == MediaType.movie
          ? '/wefeed-mobile-bff/subject-api/resource?subjectId=$matchedSubjectId&page=1&perPage=20'
          : '/wefeed-mobile-bff/subject-api/resource?subjectId=$matchedSubjectId&se=$season&ep=$episode&page=1&perPage=20';

      final resJson = await _request('GET', resPath);
      final resList = (resJson?['data']?['list'] as List?) ?? [];
      String? firstResourceId;
      for (final r in resList) {
        final rId = r['resourceId']?.toString() ?? r['id']?.toString();
        if (rId != null && rId.isNotEmpty) {
          firstResourceId = rId;
          break;
        }
      }

      final subtitles = <SubtitleTrack>[];
      if (firstResourceId != null && firstResourceId.isNotEmpty) {
        final capPath =
            '/wefeed-mobile-bff/subject-api/get-ext-captions?subjectId=$matchedSubjectId&resourceId=$firstResourceId';
        final capJson = await _request('GET', capPath);
        final caps = (capJson?['data']?['extCaptions'] ?? capJson?['data']) as List?;
        for (final c in caps ?? []) {
          final subUrl = c['url']?.toString() ?? '';
          final lan = (c['lanName'] ?? c['lan'])?.toString().trim() ?? 'Subtitles';
          final lanCode = (c['lan'] ?? 'en').toString();
          if (subUrl.startsWith('http') && !subtitles.any((s) => s.url == subUrl)) {
            subtitles.add(SubtitleTrack(
              url: subUrl,
              label: lan,
              language: lanCode,
            ));
          }
        }
      }

      if (subtitles.isEmpty) {
        final playPath = type == MediaType.movie
            ? '/wefeed-mobile-bff/subject-api/play-info/v2?subjectId=$matchedSubjectId'
            : '/wefeed-mobile-bff/subject-api/play-info/v2?subjectId=$matchedSubjectId&se=$season&ep=$episode';
        final playInfoJson = await _request('GET', playPath);
        final data = playInfoJson?['data'] ?? playInfoJson;
        if (data is Map<String, dynamic>) {
          final captions = (data['extCaptions'] as List?) ?? [];
          for (final c in captions) {
            final subUrl = c['url']?.toString() ?? '';
            final lan = (c['lanName'] ?? c['lan'])?.toString().trim() ?? 'Subtitles';
            final lanCode = (c['lan'] ?? 'en').toString();
            if (subUrl.startsWith('http') && !subtitles.any((s) => s.url == subUrl)) {
              subtitles.add(SubtitleTrack(
                url: subUrl,
                label: lan,
                language: lanCode,
              ));
            }
          }
        }
      }

      subtitles.sort((a, b) {
        final aEn = a.label.toLowerCase().contains('english');
        final bEn = b.label.toLowerCase().contains('english');
        if (aEn && !bEn) return -1;
        if (!aEn && bEn) return 1;
        return a.label.compareTo(b.label);
      });

      if (subtitles.isNotEmpty) {
        _subsCache[cacheKey] = subtitles;
      }
      return subtitles;
    } catch (e) {
      debugPrint('[MovieBox] fetchSubtitles error: $e');
      return [];
    }
  }
}

