import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';

class StorageService {
  StorageService([this._prefs]);

  SharedPreferences? _prefs;
  final Map<String, dynamic> _memoryCache = {};

  static const String _watchlistKey = 'moviehome_watchlist';
  static const String _progressPrefix = 'moviehome_progress_';

  Future<SharedPreferences?> _getPrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs;
  }

  List<MediaItem> getWatchlist() {
    final raw = _prefs?.getStringList(_watchlistKey) ??
        (_memoryCache[_watchlistKey] as List<String>?) ??
        [];
    return raw
        .map((str) {
          try {
            return MediaItem.fromJson(jsonDecode(str) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<MediaItem>()
        .toList();
  }

  Future<void> saveWatchlist(List<MediaItem> items) async {
    final list = items.map((item) => jsonEncode(item.toJson())).toList();
    _memoryCache[_watchlistKey] = list;
    final prefs = await _getPrefs();
    await prefs?.setStringList(_watchlistKey, list);
  }

  // Watch progress: saves last server, season and episode
  Map<String, dynamic>? getWatchProgress(int tmdbId, MediaType type) {
    final key = '$_progressPrefix${type.path}_$tmdbId';
    final raw = _prefs?.getString(key) ?? (_memoryCache[key] as String?);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveWatchProgress({
    required int tmdbId,
    required MediaType type,
    required String serverId,
    int season = 1,
    int episode = 1,
    int positionSeconds = 0,
  }) async {
    final key = '$_progressPrefix${type.path}_$tmdbId';
    final data = {
      'serverId': serverId,
      'season': season,
      'episode': episode,
      'positionSeconds': positionSeconds,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
    final jsonStr = jsonEncode(data);
    _memoryCache[key] = jsonStr;
    final prefs = await _getPrefs();
    await prefs?.setString(key, jsonStr);
  }
}

// Defaults to null and lazily initializes without throwing UnimplementedError
final sharedPreferencesProvider = Provider<SharedPreferences?>((ref) => null);

final storageServiceProvider = Provider<StorageService>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return StorageService(prefs);
});
