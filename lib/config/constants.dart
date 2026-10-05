/// App-wide constants. Secrets are injected at build time with
/// `--dart-define-from-file=env.json` and are never hardcoded.
class AppConstants {
  AppConstants._();

  static const String tmdbApiKey = String.fromEnvironment('TMDB_API_KEY');
  static const String tmdbBaseUrl = 'https://api.themoviedb.org/3';
  static const String tmdbImageBaseUrl = 'https://image.tmdb.org/t/p';

  static bool get hasApiKey => tmdbApiKey.isNotEmpty;
}

enum TmdbImageSize {
  w300('w300'),
  w342('w342'),
  w500('w500'),
  w780('w780'),
  w1280('w1280'),
  original('original');

  const TmdbImageSize(this.path);
  final String path;
}

String tmdbImageUrl(String? path, {TmdbImageSize size = TmdbImageSize.w500}) {
  if (path == null || path.isEmpty) return '';
  if (path.startsWith('http')) return path;
  return '${AppConstants.tmdbImageBaseUrl}/${size.path}$path';
}
