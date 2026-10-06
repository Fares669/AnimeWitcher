import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/providers/anime_data_source_settings_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/features/details/presentation/downloaded_file_provider.dart';
import 'package:animewitcher/features/details/presentation/playback_launcher.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/settings/presentation/player_settings_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Settings extends PlayerSettingsNotifier {
  @override
  Future<PlayerSettings> build() async => const PlayerSettings();
}

class _ArtworkSettings extends AnimeDataSourceSettingsNotifier {
  _ArtworkSettings(this.enabled);
  final bool enabled;
  @override
  AnimeDataSourceSettings build() => AnimeDataSourceSettings(episodeImagesFromAniZip: enabled);
}

class _Downloads extends DownloadedFiles {
  @override
  Map<String, File?> build() => {};
  @override
  Future<File?> resolveFileForTrackingUrl(String trackingUrl, {MultimediaItem? item, Episode? episode}) async => File('/tmp/episode.mp4');
}

class _History extends WatchHistory {
  Episode? opened;
  @override
  List<HistoryItem> build() => [];
  @override
  Future<void> recordOpened(MultimediaItem item, {String? lastEpisodeUrl, int? season, int? episode, String? episodeTitle, String? episodeServerName, String? episodePosterUrl}) async {
    opened = item.episodes!.firstWhere((e) => e.url == lastEpisodeUrl);
  }
}

class _Extensions extends ExtensionManager {
  _Extensions(this.provider);
  final AnimeWitcherProvider provider;
  @override
  List<AnimeWitcherProvider> build() => [provider];
}

class _Provider extends AnimeWitcherProvider {
  _Provider({this.failArtwork = false});
  final bool failArtwork;
  int catalogCalls = 0;
  int artworkCalls = 0;
  final episodes = [
    Episode(name: 'One', url: 'show|1', episode: 1, season: 1, posterUrl: 'source-1'),
    Episode(name: 'Two', url: 'show|2', episode: 2, season: 1, posterUrl: 'source-2', serverName: 'الحلقة 2', isFinal: true),
  ];
  @override
  String get packageName => 'test.artwork';
  @override
  String get name => 'Artwork';
  @override
  String get mainUrl => 'https://example.test';
  @override
  String get version => '1';
  @override
  List<String> get languages => ['ar'];
  @override
  Set<ProviderType> get supportedTypes => {ProviderType.anime};
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => {};
  @override
  Future<List<MultimediaItem>> search(String query, {CancelToken? cancelToken}) async => [];
  @override
  Future<MultimediaItem> getDetails(String url) async => MultimediaItem(title: 'Show', url: url, posterUrl: '');
  @override
  Future<List<Episode>> getEpisodes(String url) async {
    catalogCalls++;
    return episodes;
  }
  @override
  Future<List<Episode>> getEpisodeMetadata(String url) async {
    artworkCalls++;
    if (failArtwork) throw StateError('AniZip unavailable');
    // Deliberately reordered metadata with conflicting identity fields.
    return [
      Episode(name: 'Wrong', url: 'show|2', episode: 99, season: 9, posterUrl: 'anizip-2'),
      Episode(name: 'Wrong', url: 'show|1', episode: 99, season: 9, posterUrl: 'anizip-1'),
    ];
  }
  @override
  Future<List<StreamResult>> loadStreams(String url) async => [];
}

void main() {
  for (final existingCatalog in [false, true]) {
    for (final enabled in [false, true]) {
      testWidgets('resume enriches artwork enabled=$enabled existingCatalog=$existingCatalog', (tester) async {
        await _resume(tester, enabled: enabled, existingCatalog: existingCatalog);
      });
    }
  }
  testWidgets('AniZip failure preserves the playable catalog', (tester) async {
    await _resume(tester, enabled: true, existingCatalog: false, failArtwork: true);
  });
}

Future<void> _resume(WidgetTester tester, {required bool enabled, required bool existingCatalog, bool failArtwork = false}) async {
  final provider = _Provider(failArtwork: failArtwork);
  final history = _History();
  PlayerRouteExtra? player;
  final item = MultimediaItem(title: 'Show', url: 'show', posterUrl: '', provider: provider.packageName, contentType: MultimediaContentType.anime, episodes: existingCatalog ? provider.episodes : null);
  final saved = HistoryItem(item: item, position: 30, duration: 100, timestamp: 0, lastEpisodeUrl: 'show|2', episode: 2, season: 1, episodePosterUrl: 'old-2');
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (context, state) => Scaffold(body: TextButton(
      onPressed: () => unawaited(ProviderScope.containerOf(context).read(playbackLauncherProvider).playFromContinueWatching(context, saved)),
      child: const Text('resume'),
    ))),
    GoRoute(path: '/player', builder: (context, state) {
      player = state.extra! as PlayerRouteExtra;
      return const Scaffold(body: Text('player'));
    }),
  ]);
  await tester.pumpWidget(ProviderScope(overrides: [
    playerSettingsProvider.overrideWith(_Settings.new),
    animeDataSourceSettingsProvider.overrideWith(() => _ArtworkSettings(enabled)),
    downloadedFilesProvider.overrideWith(_Downloads.new),
    watchHistoryProvider.overrideWith(() => history),
    extensionManagerProvider.overrideWith(() => _Extensions(provider)),
    activeProviderProvider.overrideWithValue(provider),
  ], child: MaterialApp.router(routerConfig: router)));
  await tester.pumpAndSettle();
  await tester.tap(find.text('resume'));
  await tester.pumpAndSettle();
  expect(find.text('player'), findsOneWidget);
  expect(provider.catalogCalls, existingCatalog ? 0 : 1);
  expect(provider.artworkCalls, enabled ? 1 : 0);
  final prefix = enabled && !failArtwork ? 'anizip' : 'source';
  expect(player!.item.episodes!.map((e) => e.posterUrl), ['$prefix-1', '$prefix-2']);
  expect(player!.episode!.posterUrl, '$prefix-2');
  expect(player!.episode!.url, 'show|2');
  expect(player!.episode!.name, 'Two');
  expect(player!.episode!.episode, 2);
  expect(player!.episode!.season, 1);
  expect(player!.episode!.serverName, 'الحلقة 2');
  expect(player!.episode!.isFinal, isTrue);
  expect(history.opened!.posterUrl, '$prefix-2');
  expect(player!.progressUrl, 'show|2');
  router.pop();
  await tester.pumpAndSettle();
  await tester.pumpWidget(const SizedBox.shrink());
  router.dispose();
}
