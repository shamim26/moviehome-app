import 'dart:async';
import 'package:dio/dio.dart';
import '../../models/extracted_stream.dart';

class SubtitleCue {
  const SubtitleCue({
    required this.start,
    required this.end,
    required this.text,
  });

  final Duration start;
  final Duration end;
  final String text;
}

class HlsAndSubtitleHelper {
  HlsAndSubtitleHelper._();

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 6),
      followRedirects: true,
    ),
  );

  /// Fetches an HLS master playlist and parses available variant resolutions and subtitles.
  static Future<({List<StreamQuality> qualities, List<SubtitleTrack> subtitles})>
      inspectHlsStream({
    required String url,
    required Map<String, String> headers,
  }) async {
    final cleanQualities = <StreamQuality>[];
    final cleanSubtitles = <SubtitleTrack>[];

    try {
      final response = await _dio.get<String>(
        url,
        options: Options(
          headers: headers,
          responseType: ResponseType.plain,
        ),
      );

      final content = response.data;
      if (content == null || !content.contains('#EXTM3U')) {
        return (qualities: cleanQualities, subtitles: cleanSubtitles);
      }

      final parsed = parseHlsManifest(manifestContent: content, baseUrl: url);
      return parsed;
    } catch (_) {
      return (qualities: cleanQualities, subtitles: cleanSubtitles);
    }
  }

  /// Parses the raw text of an HLS master playlist.
  static ({List<StreamQuality> qualities, List<SubtitleTrack> subtitles})
      parseHlsManifest({
    required String manifestContent,
    required String baseUrl,
  }) {
    final baseUri = Uri.parse(baseUrl);
    final lines = manifestContent.split(RegExp(r'\r?\n'));

    final qualities = <StreamQuality>[];
    final subtitles = <SubtitleTrack>[];
    final seenQualities = <String>{};
    final seenSubs = <String>{};

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();

      // Parse Subtitle tracks: #EXT-X-MEDIA:TYPE=SUBTITLES,...
      if (line.startsWith('#EXT-X-MEDIA:') && line.contains('TYPE=SUBTITLES')) {
        final nameMatch = RegExp(r'NAME="([^"]+)"').firstMatch(line);
        final langMatch = RegExp(r'LANGUAGE="([^"]+)"').firstMatch(line);
        final uriMatch = RegExp(r'URI="([^"]+)"').firstMatch(line);

        final label = nameMatch?.group(1) ?? langMatch?.group(1) ?? 'Subtitle';
        final lang = langMatch?.group(1) ?? 'en';
        final rawUri = uriMatch?.group(1);

        if (rawUri != null && rawUri.isNotEmpty) {
          final resolvedUri = baseUri.resolve(rawUri).toString();
          if (!seenSubs.contains(resolvedUri)) {
            seenSubs.add(resolvedUri);
            subtitles.add(SubtitleTrack(
              url: resolvedUri,
              label: label,
              language: lang,
            ));
          }
        }
      }

      // Parse Variant streams: #EXT-X-STREAM-INF:...
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        // Next non-empty, non-comment line is the variant URL
        String? variantUri;
        for (int j = i + 1; j < lines.length; j++) {
          final nextLine = lines[j].trim();
          if (nextLine.isNotEmpty && !nextLine.startsWith('#')) {
            variantUri = nextLine;
            break;
          }
        }

        if (variantUri != null) {
          final resMatch =
              RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(line);
          final nameMatch = RegExp(r'NAME="([^"]+)"').firstMatch(line);

          String qualityLabel = 'HD';
          int height = 0;
          if (resMatch != null) {
            height = int.tryParse(resMatch.group(2) ?? '0') ?? 0;
            if (height >= 2160) {
              qualityLabel = '4K';
            } else if (height >= 1440) {
              qualityLabel = '1440p';
            } else if (height >= 1080) {
              qualityLabel = '1080p';
            } else if (height >= 720) {
              qualityLabel = '720p';
            } else if (height >= 480) {
              qualityLabel = '480p';
            } else if (height >= 360) {
              qualityLabel = '360p';
            } else if (height > 0) {
              qualityLabel = '${height}p';
            }
          } else if (nameMatch != null) {
            qualityLabel = nameMatch.group(1)!;
          }

          final resolved = baseUri.resolve(variantUri).toString();
          if (!seenQualities.contains(qualityLabel)) {
            seenQualities.add(qualityLabel);
            qualities.add(StreamQuality(
              label: qualityLabel,
              url: resolved,
            ));
          }
        }
      }
    }

    final finalQualities = <StreamQuality>[];
    if (qualities.isNotEmpty) {
      // Prepend Auto option pointing to master playlist
      finalQualities.add(StreamQuality(label: 'Auto', url: baseUrl));
      finalQualities.addAll(qualities);
    }

    return (qualities: finalQualities, subtitles: subtitles);
  }

  /// Downloads and parses WebVTT or SRT subtitles into cue objects.
  static Future<List<SubtitleCue>> fetchAndParseSubtitles({
    required String url,
    Map<String, String>? headers,
  }) async {
    try {
      final response = await _dio.get<String>(
        url,
        options: Options(
          headers: headers,
          responseType: ResponseType.plain,
        ),
      );

      final text = response.data;
      if (text == null || text.isEmpty) return [];

      // If the subtitle URL is an HLS sub playlist (.m3u8), look for the first .vtt segment
      if (text.contains('#EXTM3U') && text.contains('.vtt')) {
        final base = Uri.parse(url);
        final lines = text.split(RegExp(r'\r?\n'));
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isNotEmpty && !trimmed.startsWith('#') && trimmed.contains('.vtt')) {
            final vttUrl = base.resolve(trimmed).toString();
            return await fetchAndParseSubtitles(url: vttUrl, headers: headers);
          }
        }
      }

      return parseSubtitles(text);
    } catch (_) {
      if (headers != null && headers.isNotEmpty) {
        try {
          final response = await _dio.get<String>(
            url,
            options: Options(responseType: ResponseType.plain),
          );
          final text = response.data;
          if (text != null && text.isNotEmpty) return parseSubtitles(text);
        } catch (_) {}
      }
      return [];
    }
  }

  /// Parses WebVTT or SRT text into [SubtitleCue] instances.
  static List<SubtitleCue> parseSubtitles(String content) {
    final cues = <SubtitleCue>[];
    final lines = content.split(RegExp(r'\r?\n'));

    // Matches e.g. "00:01:20.000 --> 00:01:23.000" or "01:20,000 --> 01:23,000"
    final timeRegex = RegExp(
      r'((?:\d{1,2}:)?\d{2}:\d{2}[.,]\d{3})\s*-->\s*((?:\d{1,2}:)?\d{2}:\d{2}[.,]\d{3})',
    );

    Duration? currentStart;
    Duration? currentEnd;
    final textBuffer = StringBuffer();

    void emitCue() {
      if (currentStart != null && currentEnd != null && textBuffer.isNotEmpty) {
        final rawText = textBuffer.toString().trim();
        // Strip HTML styling tags (e.g. <b>, <i>, <c.yellow>, <v ...>)
        final cleanText = rawText.replaceAll(RegExp(r'<[^>]*>'), '').trim();
        if (cleanText.isNotEmpty) {
          cues.add(SubtitleCue(
            start: currentStart!,
            end: currentEnd!,
            text: cleanText,
          ));
        }
      }
      currentStart = null;
      currentEnd = null;
      textBuffer.clear();
    }

    for (final line in lines) {
      final trimmed = line.trim();

      final match = timeRegex.firstMatch(trimmed);
      if (match != null) {
        emitCue();
        currentStart = _parseTimestamp(match.group(1)!);
        currentEnd = _parseTimestamp(match.group(2)!);
      } else if (currentStart != null && trimmed.isNotEmpty) {
        // Skip cue number lines (e.g. "1", "2") in SRT
        if (RegExp(r'^\d+$').hasMatch(trimmed) && textBuffer.isEmpty) {
          continue;
        }
        if (textBuffer.isNotEmpty) textBuffer.write('\n');
        textBuffer.write(trimmed);
      } else if (trimmed.isEmpty && currentStart != null) {
        emitCue();
      }
    }

    emitCue();
    cues.sort((a, b) => a.start.compareTo(b.start));
    return cues;
  }

  static Duration _parseTimestamp(String raw) {
    try {
      final clean = raw.replaceAll(',', '.');
      final parts = clean.split(':');
      if (parts.length == 3) {
        final h = int.tryParse(parts[0]) ?? 0;
        final m = int.tryParse(parts[1]) ?? 0;
        final secParts = parts[2].split('.');
        final s = int.tryParse(secParts[0]) ?? 0;
        final ms = secParts.length > 1
            ? int.tryParse(secParts[1].padRight(3, '0').substring(0, 3)) ?? 0
            : 0;
        return Duration(hours: h, minutes: m, seconds: s, milliseconds: ms);
      } else if (parts.length == 2) {
        final m = int.tryParse(parts[0]) ?? 0;
        final secParts = parts[1].split('.');
        final s = int.tryParse(secParts[0]) ?? 0;
        final ms = secParts.length > 1
            ? int.tryParse(secParts[1].padRight(3, '0').substring(0, 3)) ?? 0
            : 0;
        return Duration(minutes: m, seconds: s, milliseconds: ms);
      }
    } catch (_) {}
    return Duration.zero;
  }
}
