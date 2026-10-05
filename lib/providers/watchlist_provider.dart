import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/media_item.dart';
import '../services/storage_service.dart';

class WatchlistNotifier extends Notifier<List<MediaItem>> {
  @override
  List<MediaItem> build() {
    final storage = ref.watch(storageServiceProvider);
    return storage.getWatchlist();
  }

  bool isBookmarked(int id, MediaType type) {
    return state.any((item) => item.id == id && item.mediaType == type);
  }

  Future<void> toggle(MediaItem item) async {
    final storage = ref.read(storageServiceProvider);
    final exists = isBookmarked(item.id, item.mediaType);
    final updated = exists
        ? state.where((m) => !(m.id == item.id && m.mediaType == item.mediaType)).toList()
        : [item, ...state];

    state = updated;
    await storage.saveWatchlist(updated);
  }
}

final watchlistProvider =
    NotifierProvider<WatchlistNotifier, List<MediaItem>>(WatchlistNotifier.new);
