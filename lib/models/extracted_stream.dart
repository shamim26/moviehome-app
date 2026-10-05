import 'stream_server.dart';

class SubtitleTrack {
  const SubtitleTrack({
    required this.url,
    required this.label,
    required this.language,
  });

  final String url;
  final String label;
  final String language;

  factory SubtitleTrack.fromJson(Map<String, dynamic> json) => SubtitleTrack(
        url: json['file'] as String? ?? json['url'] as String? ?? '',
        label: json['label'] as String? ?? json['lang'] as String? ?? 'English',
        language: json['language'] as String? ?? 'en',
      );
}

class ExtractedStream {
  const ExtractedStream({
    required this.url,
    required this.headers,
    required this.server,
    this.quality = 'Auto',
    this.subtitles = const [],
  });

  final String url;
  final Map<String, String> headers;
  final StreamServer server;
  final String quality;
  final List<SubtitleTrack> subtitles;

  bool get isHls => url.contains('.m3u8') || url.contains('/hls/');
}
