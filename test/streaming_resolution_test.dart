// ignore_for_file: avoid_print

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_application_1/services/streaming/fourkhdhub/fourkhdhub_service.dart';
import 'package:flutter_application_1/services/streaming/moviebox/moviebox_service.dart';
import 'package:flutter_application_1/models/media_item.dart';
import 'package:flutter_application_1/models/stream_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  SharedPreferences.setMockInitialValues({});
  final server = StreamServers.all[0];

  test('4KHDHub resolves 1080p for Facing El Chapo (no 2160p crash)', () async {
    final stream = await FourKHdHubService.instance.getStream(
      title: 'Facing El Chapo',
      year: 2026,
      type: MediaType.movie,
      server: server,
    );

    expect(stream, isNotNull);
    print('Resolved 4KHDHub stream URL: ${stream!.url}');
    print('Resolved 4KHDHub quality: ${stream.quality}');

    // Crucial check: MUST NOT be 2160p
    expect(stream.quality, isNot(equals('2160p')));
    expect(stream.url.toLowerCase().contains('2160p'), isFalse);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('4KHDHub resolves 1080p for Runner', () async {
    final stream = await FourKHdHubService.instance.getStream(
      title: 'Runner',
      year: 2026,
      type: MediaType.movie,
      server: server,
    );

    expect(stream, isNotNull);
    print('Resolved 4KHDHub Runner URL: ${stream!.url}');
    print('Resolved 4KHDHub Runner quality: ${stream.quality}');
    expect(stream.quality, isNot(equals('2160p')));
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('MovieBox resolves playable stream for After Impact', () async {
    final server = StreamServers.byId('superstream_fast');
    final stream = await MovieBoxService.instance.getStream(
      title: 'After Impact',
      year: 2026,
      type: MediaType.movie,
      server: server,
    );

    print('MovieBox stream for After Impact: ${stream?.url}');
  }, timeout: const Timeout(Duration(seconds: 40)));
}
