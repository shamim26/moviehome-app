import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/media_details.dart';
import '../models/media_item.dart';
import '../services/tmdb_service.dart';

typedef DetailKey = ({int id, MediaType type});

/// Full details (cast, trailer, seasons, recommendations) for one title.
/// Keeps data alive in memory for 10 minutes so returning to a title is instantaneous.
final mediaDetailsProvider =
    FutureProvider.autoDispose.family<MediaDetails, DetailKey>(
  (ref, key) {
    final link = ref.keepAlive();
    final timer = Timer(const Duration(minutes: 10), () => link.close());
    ref.onDispose(() => timer.cancel());
    return ref.watch(tmdbServiceProvider).details(key.id, key.type);
  },
);
