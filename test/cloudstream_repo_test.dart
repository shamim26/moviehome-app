// ignore_for_file: avoid_print

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_application_1/models/media_item.dart';
import 'package:flutter_application_1/models/stream_server.dart';
import 'package:flutter_application_1/services/streaming/cloudstream/core/repo_manager.dart';
import 'package:flutter_application_1/services/streaming/cloudstream/providers/sflix_provider.dart';
import 'package:flutter_application_1/services/streaming/cloudstream/providers/hianime_provider.dart';
import 'package:flutter_application_1/services/streaming/cloudstream/providers/animeflv_provider.dart';
import 'package:flutter_application_1/services/streaming/cloudstream/providers/sorastream_provider.dart';
import 'package:flutter_application_1/services/streaming/cloudstream/providers/fmovies_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  SharedPreferences.setMockInitialValues({});

  test('CloudStreamRepoManager initializes pre-injected repositories and providers', () {
    final manager = CloudStreamRepoManager.instance;
    expect(manager.repos, isNotEmpty);
    expect(manager.allProviders.length, equals(10));

    final servers = manager.getStreamServers();
    expect(servers.length, equals(10));
    expect(servers[0].id, equals('4khdhub'));
    expect(servers[1].id, equals('fastcloud'));
    expect(servers[2].id, equals('superstream_fast'));
    expect(servers[3].id, equals('sorastream'));
    expect(servers[4].id, equals('sflix'));
    expect(servers[5].id, equals('fmovies'));
    expect(servers[6].id, equals('hianime'));
    expect(servers[7].id, equals('animeflv'));
    expect(servers[8].id, equals('hdhub4u'));
    expect(servers[9].id, equals('moviebox'));

    // Verify independent provider types
    expect(manager.getProvider('sorastream'), isA<SorastreamProvider>());
    expect(manager.getProvider('sflix'), isA<SflixProvider>());
    expect(manager.getProvider('hianime'), isA<HiAnimeProvider>());
    expect(manager.getProvider('fmovies'), isA<FmoviesProvider>());
    expect(manager.getProvider('animeflv'), isA<AnimeFlvProvider>());
  });

  test('CloudStream resolves Server 1 (4KHDHub R2 Edge) for Runner WITH subtitles', () async {
    final server1 = StreamServers.all[0];
    expect(server1.id, equals('4khdhub'));

    final stream = await CloudStreamRepoManager.instance.resolveStream(
      providerId: server1.id,
      tmdbId: 12345,
      title: 'Runner',
      year: 2026,
      type: MediaType.movie,
      server: server1,
    );

    expect(stream, isNotNull);
    print('CloudStream Server 1 resolved URL: ${stream!.url}');
    print('CloudStream Server 1 subtitles count: ${stream.subtitles.length}');
    expect(stream.url.isNotEmpty, isTrue);
    expect(stream.subtitles.isNotEmpty, isTrue);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('CloudStream resolves Server 9 (SuperStream Fast CDN) for Runner', () async {
    final server = StreamServers.byId('superstream_fast');
    expect(server.id, equals('superstream_fast'));

    final stream = await CloudStreamRepoManager.instance.resolveStream(
      providerId: server.id,
      tmdbId: 12345,
      title: 'Runner',
      year: 2026,
      type: MediaType.movie,
      server: server,
    );

    expect(stream, isNotNull);
    print('CloudStream SuperStream resolved URL: ${stream!.url}');
    print('CloudStream SuperStream qualities count: ${stream.qualities.length}');
    print('CloudStream SuperStream subtitles count: ${stream.subtitles.length}');
    expect(stream.url.isNotEmpty, isTrue);
    expect(stream.subtitles.isNotEmpty, isTrue);
  }, timeout: const Timeout(Duration(seconds: 40)));
}
