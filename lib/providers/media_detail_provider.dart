import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/media_details.dart';
import '../models/media_item.dart';
import '../services/tmdb_service.dart';

typedef DetailKey = ({int id, MediaType type});

/// Full details (cast, trailer, seasons, recommendations) for one title.
final mediaDetailsProvider =
    FutureProvider.autoDispose.family<MediaDetails, DetailKey>(
  (ref, key) => ref.watch(tmdbServiceProvider).details(key.id, key.type),
);
