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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubtitleTrack &&
          runtimeType == other.runtimeType &&
          url == other.url;

  @override
  int get hashCode => url.hashCode;
}

class StreamQuality {
  const StreamQuality({
    required this.label,
    required this.url,
  });

  final String label;
  final String url;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StreamQuality &&
          runtimeType == other.runtimeType &&
          label == other.label &&
          url == other.url;

  @override
  int get hashCode => label.hashCode ^ url.hashCode;
}

class ExtractedStream {
  const ExtractedStream({
    required this.url,
    required this.headers,
    required this.server,
    this.quality = 'Auto',
    this.qualities = const [],
    this.subtitles = const [],
  });

  final String url;
  final Map<String, String> headers;
  final StreamServer server;
  final String quality;
  final List<StreamQuality> qualities;
  final List<SubtitleTrack> subtitles;

  bool get isHls => url.contains('.m3u8') || url.contains('/hls/');

  ExtractedStream copyWith({
    String? url,
    Map<String, String>? headers,
    StreamServer? server,
    String? quality,
    List<StreamQuality>? qualities,
    List<SubtitleTrack>? subtitles,
  }) {
    return ExtractedStream(
      url: url ?? this.url,
      headers: headers ?? this.headers,
      server: server ?? this.server,
      quality: quality ?? this.quality,
      qualities: qualities ?? this.qualities,
      subtitles: subtitles ?? this.subtitles,
    );
  }
}
