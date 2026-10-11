import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../../models/extracted_stream.dart';

class _DashSession {
  _DashSession({
    required this.originalMpdUrl,
    required this.headers,
    this.rawMpdXml,
    required this.createdAt,
  });

  final String originalMpdUrl;
  final Map<String, String> headers;
  String? rawMpdXml;
  final DateTime createdAt;
}

/// A lightweight local loopback proxy that sanitizes MovieBox DASH manifests.
///
/// On devices with hardware decoder constraints (like Snapdragon 685 where HEVC max width
/// is 2048 px), MovieBox's 21:9 1080p stream (encoded at 2592x1080) causes
/// MediaCodec native_configure to throw BAD_VALUE (-22).
///
/// This proxy:
/// 1. Fetches the remote MPD from MovieBox CDN using signed cookies/headers.
/// 2. Injects `<BaseURL>` so ExoPlayer fetches segments directly from the CDN.
/// 3. Filters out video representations with width > 2048 to prevent decoder crashes.
/// 4. Enables quality switching (e.g., 720p, 480p) by filtering representations.
class MovieBoxDashProxy {
  MovieBoxDashProxy._();
  static final MovieBoxDashProxy instance = MovieBoxDashProxy._();

  HttpServer? _server;
  int? _port;
  final Map<String, _DashSession> _sessions = {};
  final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  /// Initializes or returns the listening port on loopback IPv4.
  Future<int> getPort() async {
    if (_server != null && _port != null) {
      return _port!;
    }
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    debugPrint('[MovieBoxDashProxy] Started loopback proxy on port $_port');
    _server!.listen(_handleRequest, onError: (e) {
      debugPrint('[MovieBoxDashProxy] Server error: $e');
    });
    return _port!;
  }

  /// Registers a DASH stream session and discovers safe resolutions, returning master URL and qualities.
  Future<({String masterUrl, List<StreamQuality> qualities})> registerDashStream({
    required String originalMpdUrl,
    required Map<String, String> headers,
  }) async {
    final port = await getPort();
    final sessionId = originalMpdUrl.hashCode.abs().toString();

    // 1. Fetch remote MPD to discover valid resolutions and pre-cache
    String rawXml = '';
    try {
      final clientReq = await _httpClient.getUrl(Uri.parse(originalMpdUrl));
      headers.forEach((k, v) => clientReq.headers.set(k, v));
      final clientRes = await clientReq.close();
      if (clientRes.statusCode == HttpStatus.ok) {
        rawXml = await utf8.decodeStream(clientRes);
      }
    } catch (e) {
      debugPrint('[MovieBoxDashProxy] Error pre-fetching MPD: $e');
    }

    _sessions[sessionId] = _DashSession(
      originalMpdUrl: originalMpdUrl,
      headers: headers,
      rawMpdXml: rawXml.isNotEmpty ? rawXml : null,
      createdAt: DateTime.now(),
    );

    // Clean up old sessions (> 2 hours)
    final now = DateTime.now();
    _sessions.removeWhere(
      (_, s) => now.difference(s.createdAt).inHours > 2,
    );

    final masterUrl = 'http://127.0.0.1:$port/manifest.mpd?id=$sessionId';
    final qualities = <StreamQuality>[
      StreamQuality(label: 'Auto', url: masterUrl),
    ];

    if (rawXml.isNotEmpty) {
      final repRegex = RegExp(r'<Representation\s+([^>]*?)>([\s\S]*?)</Representation>');
      final validHeights = <int>{};
      for (final match in repRegex.allMatches(rawXml)) {
        final attrs = match.group(1)!;
        if (attrs.contains('mimeType="audio') || attrs.contains('codecs="mp4a')) continue;
        final widthMatch = RegExp(r'\bwidth="(\d+)"').firstMatch(attrs);
        final heightMatch = RegExp(r'\bheight="(\d+)"').firstMatch(attrs);
        final width = widthMatch != null ? int.tryParse(widthMatch.group(1)!) ?? 0 : 0;
        final height = heightMatch != null ? int.tryParse(heightMatch.group(1)!) ?? 0 : 0;
        if (height > 0 && width <= 2048) {
          validHeights.add(height);
        }
      }

      final sortedHeights = validHeights.toList()..sort((a, b) => b.compareTo(a));
      for (final h in sortedHeights) {
        final qUrl = 'http://127.0.0.1:$port/manifest.mpd?id=$sessionId&h=$h';
        qualities.add(StreamQuality(label: '${h}p', url: qUrl));
      }
    }

    return (masterUrl: masterUrl, qualities: qualities);
  }

  /// Registers a DASH stream session and returns the local proxy URL for a target height.
  Future<String> registerSession({
    required String originalMpdUrl,
    required Map<String, String> headers,
    int? targetHeight,
  }) async {
    final port = await getPort();
    final sessionId = originalMpdUrl.hashCode.abs().toString();

    _sessions[sessionId] = _DashSession(
      originalMpdUrl: originalMpdUrl,
      headers: headers,
      createdAt: DateTime.now(),
    );

    // Clean up old sessions (> 2 hours)
    final now = DateTime.now();
    _sessions.removeWhere(
      (_, s) => now.difference(s.createdAt).inHours > 2,
    );

    final heightParam = targetHeight != null ? '&h=$targetHeight' : '';
    return 'http://127.0.0.1:$port/manifest.mpd?id=$sessionId$heightParam';
  }

  /// Sanitizes raw MPD XML by injecting `<BaseURL>` and filtering representations.
  static String sanitizeMpd(
    String rawXml, {
    required String baseUrl,
    int? targetHeight,
    int maxWidthAllowed = 2048,
  }) {
    var xml = rawXml;

    // 1. Inject <BaseURL> right after <MPD ...> if not already present
    if (!xml.contains('<BaseURL>')) {
      final mpdTagMatch = RegExp(r'<MPD[^>]*>').firstMatch(xml);
      if (mpdTagMatch != null) {
        final idx = mpdTagMatch.end;
        xml = '${xml.substring(0, idx)}\n\t<BaseURL>$baseUrl</BaseURL>${xml.substring(idx)}';
      }
    }

    // 2. Parse video AdaptationSet representations
    // Match each <Representation ...>...</Representation> block
    final repRegex = RegExp(
      r'<Representation\s+([^>]*?)>([\s\S]*?)</Representation>',
    );

    final Map<String, String> repIdToSanitized = {};
    int maxRemainingWidth = 0;
    int maxRemainingHeight = 0;

    for (final match in repRegex.allMatches(xml)) {
      final fullTag = match.group(0)!;
      final attrs = match.group(1)!;

      final idMatch = RegExp(r'\bid="([^"]+)"').firstMatch(attrs);
      final repId = idMatch?.group(1) ?? fullTag;

      // Check if it's audio (mimeType="audio/..." or codecs starting with mp4a)
      if (attrs.contains('mimeType="audio') || attrs.contains('codecs="mp4a')) {
        // Keep all audio representations
        repIdToSanitized[repId] = fullTag;
        continue;
      }

      // Extract width and height
      final widthMatch = RegExp(r'\bwidth="(\d+)"').firstMatch(attrs);
      final heightMatch = RegExp(r'\bheight="(\d+)"').firstMatch(attrs);
      final width = widthMatch != null ? int.tryParse(widthMatch.group(1)!) ?? 0 : 0;
      final height = heightMatch != null ? int.tryParse(heightMatch.group(1)!) ?? 0 : 0;

      // If specific height requested, filter by it
      if (targetHeight != null && height > 0) {
        if (height != targetHeight) {
          continue; // Skip representation not matching target height
        }
      }

      // Check hardware decoder limit (max width <= 2048)
      if (width > maxWidthAllowed) {
        debugPrint('[MovieBoxDashProxy] Filtering out oversized representation: ${width}x$height (limit: $maxWidthAllowed)');
        continue;
      }

      // Align width to multiple of 16 to prevent Qualcomm CCodec (c2.qti.hevc.decoder)
      // from throwing BAD_VALUE (-22) when width % 16 != 0 (e.g. 1994x1080 -> 2000x1080)
      var sanitizedTag = fullTag;
      int effectiveWidth = width;
      if (width > 0 && width % 16 != 0) {
        final aligned = ((width + 15) ~/ 16) * 16;
        effectiveWidth = aligned <= maxWidthAllowed ? aligned : ((maxWidthAllowed ~/ 16) * 16);
        sanitizedTag = sanitizedTag.replaceAllMapped(
          RegExp(r'\bwidth="\d+"'),
          (_) => 'width="$effectiveWidth"',
        );
        debugPrint('[MovieBoxDashProxy] Aligned representation width $width -> $effectiveWidth for hardware decoder compatibility');
      }

      if (effectiveWidth > maxRemainingWidth) maxRemainingWidth = effectiveWidth;
      if (height > maxRemainingHeight) maxRemainingHeight = height;
      repIdToSanitized[repId] = sanitizedTag;
    }

    // If all video representations were filtered out (edge case), fall back to smallest video rep
    final hasVideo = repIdToSanitized.values.any((r) => r.contains('width='));
    if (!hasVideo) {
      int minWidth = 99999;
      String? smallestRepId;
      String? smallestRep;
      for (final match in repRegex.allMatches(rawXml)) {
        final fullTag = match.group(0)!;
        final attrs = match.group(1)!;
        final widthMatch = RegExp(r'width="(\d+)"').firstMatch(attrs);
        final width = widthMatch != null ? int.tryParse(widthMatch.group(1)!) ?? 0 : 0;
        final idMatch = RegExp(r'\bid="([^"]+)"').firstMatch(attrs);
        final repId = idMatch?.group(1) ?? fullTag;
        if (width > 0 && width < minWidth) {
          minWidth = width;
          smallestRepId = repId;
          var sanitized = fullTag;
          if (width % 16 != 0) {
            final aligned = ((width + 15) ~/ 16) * 16;
            final effective = aligned <= maxWidthAllowed ? aligned : ((maxWidthAllowed ~/ 16) * 16);
            sanitized = sanitized.replaceAllMapped(
              RegExp(r'\bwidth="\d+"'),
              (_) => 'width="$effective"',
            );
          }
          smallestRep = sanitized;
        }
      }
      if (smallestRep != null && smallestRepId != null) {
        repIdToSanitized[smallestRepId] = smallestRep;
      }
    }

    // Replace all representations in XML with kept and sanitized ones
    xml = xml.replaceAllMapped(repRegex, (m) {
      final attrs = m.group(1)!;
      final idMatch = RegExp(r'\bid="([^"]+)"').firstMatch(attrs);
      final repId = idMatch?.group(1) ?? m.group(0)!;
      if (repIdToSanitized.containsKey(repId)) {
        return repIdToSanitized[repId]!;
      }
      return ''; // Strip filtered representation
    });

    // Update maxWidth and maxHeight in AdaptationSet if we know them
    if (maxRemainingWidth > 0) {
      xml = xml.replaceAll(RegExp(r'maxWidth="\d+"'), 'maxWidth="$maxRemainingWidth"');
      xml = xml.replaceAllMapped(RegExp(r'<AdaptationSet\b([^>]*)>'), (m) {
        var asTag = m.group(0)!;
        asTag = asTag.replaceAllMapped(RegExp(r'\bwidth="\d+"'), (_) => 'width="$maxRemainingWidth"');
        return asTag;
      });
    }
    if (maxRemainingHeight > 0) {
      xml = xml.replaceAll(RegExp(r'maxHeight="\d+"'), 'maxHeight="$maxRemainingHeight"');
    }

    return xml;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', '*');

    if (request.method == 'OPTIONS') {
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }

    final uri = request.uri;
    final sessionId = uri.queryParameters['id'];
    final session = sessionId != null ? _sessions[sessionId] : null;

    if (session == null) {
      response.statusCode = HttpStatus.notFound;
      response.write('Session not found or expired');
      await response.close();
      return;
    }

    final targetHeight = int.tryParse(uri.queryParameters['h'] ?? '');

    try {
      // Fetch or use cached MPD
      String rawXml = session.rawMpdXml ?? '';
      if (rawXml.isEmpty) {
        final clientReq = await _httpClient.getUrl(Uri.parse(session.originalMpdUrl));
        session.headers.forEach((k, v) => clientReq.headers.set(k, v));
        final clientRes = await clientReq.close();
        if (clientRes.statusCode != HttpStatus.ok) {
          response.statusCode = clientRes.statusCode;
          response.write('Upstream error: ${clientRes.statusCode}');
          await response.close();
          return;
        }
        rawXml = await utf8.decodeStream(clientRes);
        session.rawMpdXml = rawXml;
      }

      // Base URL is the directory containing index.mpd
      final baseUri = session.originalMpdUrl.substring(
        0,
        session.originalMpdUrl.lastIndexOf('/') + 1,
      );

      final sanitized = sanitizeMpd(
        rawXml,
        baseUrl: baseUri,
        targetHeight: targetHeight,
      );

      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType('application', 'dash+xml', charset: 'utf-8');
      response.headers.set('Cache-Control', 'no-cache');
      response.write(sanitized);
      await response.close();
    } catch (e, st) {
      debugPrint('[MovieBoxDashProxy] Error handling request: $e\n$st');
      response.statusCode = HttpStatus.internalServerError;
      response.write('Internal Proxy Error: $e');
      await response.close();
    }
  }

  void dispose() {
    _server?.close(force: true);
    _server = null;
    _port = null;
    _sessions.clear();
  }
}
