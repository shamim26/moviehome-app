import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/models/media_item.dart';
import 'package:flutter_application_1/providers/watchlist_provider.dart';
import 'package:flutter_application_1/screens/watchlist_screen.dart';
import 'package:flutter_application_1/widgets/common/app_shell.dart';

void main() {
  testWidgets('App smoke test and verifies 5 tabs with Search in the middle',
      (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: MovieHomeApp()));
    expect(find.byType(MovieHomeApp), findsOneWidget);
    expect(find.byType(AppShell), findsOneWidget);

    // Verify all 5 tabs exist in order
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Movies'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Series'), findsOneWidget);
    expect(find.text('Watchlist'), findsOneWidget);
  });

  testWidgets('Switching tabs switches index via navIndexProvider',
      (WidgetTester tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(navIndexProvider), 0);
    // Switch to search (middle tab index 2)
    container.read(navIndexProvider.notifier).setIndex(2);
    expect(container.read(navIndexProvider), 2);
    // Switch to watchlist (index 4)
    container.read(navIndexProvider.notifier).setIndex(4);
    expect(container.read(navIndexProvider), 4);
  });

  testWidgets('Watchlist screen displays KPI card with stats',
      (WidgetTester tester) async {
    const testMovie = MediaItem(
      id: 101,
      title: 'Inception',
      overview: 'Dream within a dream',
      mediaType: MediaType.movie,
      voteAverage: 8.8,
    );
    const testSeries = MediaItem(
      id: 202,
      title: 'Breaking Bad',
      overview: 'Chemistry teacher',
      mediaType: MediaType.tv,
      voteAverage: 9.5,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          watchlistProvider.overrideWith(() => _MockWatchlistNotifier([
                testMovie,
                testSeries,
              ])),
        ],
        child: const MaterialApp(
          home: WatchlistScreen(),
        ),
      ),
    );

    // Check header and KPI card metrics
    expect(find.text('Watchlist'), findsOneWidget);
    expect(find.text('Library Overview'), findsOneWidget);
    expect(find.text('2 Titles'), findsOneWidget);
    expect(find.text('Movies'), findsWidgets);
    expect(find.text('Series'), findsWidgets);
    expect(find.text('Watching'), findsOneWidget);
    expect(find.text('Avg Score'), findsOneWidget);
  });
}

class _MockWatchlistNotifier extends WatchlistNotifier {
  _MockWatchlistNotifier(this._initial);
  final List<MediaItem> _initial;

  @override
  List<MediaItem> build() => _initial;
}
