import '../models/cloudstream_models.dart';

/// Base class for all video extractors.
/// Ported from com.lagradost.cloudstream3.utils.ExtractorApi
abstract class ExtractorApi {
  String get name;
  String get mainUrl;
  bool get requiresReferer => true;

  /// Extracts direct video stream links from an embed URL.
  Future<List<CloudStreamExtractorLink>> extract(
    String url, {
    String? referer,
    Map<String, String>? headers,
  });
}
