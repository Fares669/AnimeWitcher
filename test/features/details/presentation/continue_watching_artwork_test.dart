import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/providers/anime_data_source_settings_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/utils/episode_label.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_control_components.dart';
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
  AnimeDataSourceSettings build() =>
      AnimeDataSourceSettings(episodeImagesFromAniZip: enabled);
}

class _Downloads extends DownloadedFiles {
  _Downloads(this.local);
  final bool local;
  @override
  Map<String, File?> build() => {};
  @override
  Future<File?> resolveFileForTrackingUrl(
    String trackingUrl, {
    MultimediaItem? item,
    Episode? episode,
  }) async => local ? File('/tmp/episode.mp4') : null;
  @override
  Future<File?> resolveFile(
    MultimediaItem item, {
    Episode? episode,
    String? logicalId,
  }) async => null;
}

class _History extends WatchHistory {
  Episode? opened;
  String? storedTitle;
  String? storedServerName;
  String? storedServerNumber;
  @override
  List<HistoryItem> build() => [];
  @override
  Future<void> recordOpened(
    MultimediaItem item, {
    String? lastEpisodeUrl,
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodeServerName,
    String? episodeServerNumber,
    String? episodePosterUrl,
  }) async {
    opened = item.episodes!.firstWhere((e) => e.url == lastEpisodeUrl);
    storedTitle = episodeTitle;
    storedServerName = episodeServerName;
    storedServerNumber = episodeServerNumber;
  }
}

class _Extensions extends ExtensionManager {
  _Extensions(this.provider);
  final AnimeWitcherProvider provider;
  @override
  List<AnimeWitcherProvider> build() => [provider];
}

class _Provider extends AnimeWitcherProvider {
  _Provider({
    this.failArtwork = false,
    this.hangCatalog = false,
    this.hangArtwork = false,
  });
  final bool hangCatalog;
  final bool hangArtwork;
  final bool failArtwork;
  int catalogCalls = 0;
  int artworkCalls = 0;
  final episodes = [
    Episode(
      name: 'One',
      url: 'show|1',
      episode: 1,
      season: 1,
      posterUrl: 'source-1',
    ),
    Episode(
      name: 'Two',
      url: 'show|2',
      episode: 2,
      season: 1,
      posterUrl: 'source-2',
      serverName: 'الحلقة 2',
      isFinal: true,
    ),
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
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => [];
  @override
  Future<MultimediaItem> getDetails(String url) async =>
      MultimediaItem(title: 'Show', url: url, posterUrl: '');
  @override
  Future<List<Episode>> getEpisodes(String url) async {
    catalogCalls++;
    if (hangCatalog) return Completer<List<Episode>>().future;
    return episodes;
  }

  @override
  Future<List<Episode>> getEpisodeMetadata(String url) async {
    artworkCalls++;
    if (hangArtwork) return Completer<List<Episode>>().future;
    if (failArtwork) throw StateError('AniZip unavailable');
    // Deliberately reordered metadata with conflicting identity fields.
    return [
      Episode(
        name: 'Wrong',
        url: 'show|2',
        episode: 99,
        season: 9,
        posterUrl: 'anizip-2',
      ),
      Episode(
        name: 'Wrong',
        url: 'show|1',
        episode: 99,
        season: 9,
        posterUrl: 'anizip-1',
      ),
    ];
  }

  @override
  Future<List<StreamResult>> loadStreams(String url) async => [];
}

void main() {
  for (final local in [false, true]) {
    for (final existingCatalog in [false, true]) {
      for (final enabled in [false, true]) {
        testWidgets(
          'resume local=$local artwork=$enabled existingCatalog=$existingCatalog',
          (tester) async {
            await _resume(
              tester,
              enabled: enabled,
              existingCatalog: existingCatalog,
              local: local,
            );
          },
        );
      }
    }
  }
  for (final local in [false, true]) {
    for (final label in ['الحلقة ٢.٥', 'الحلقة الخاصة: العودة / الجزء؟']) {
      testWidgets(
        'history resume renders original server label local=$local label=$label',
        (tester) async {
          await _resume(
            tester,
            enabled: true,
            existingCatalog: false,
            local: local,
            originalEpisode: Episode(
              name: '',
              url: 'show|2',
              episode: 2,
              season: 1,
              posterUrl: 'source-2',
              serverName: label,
              serverNumber: '٢.٥',
            ),
          );
        },
      );
    }
  }
  testWidgets('pending catalog cannot block a selected stream', (tester) async {
    await _resume(
      tester,
      enabled: true,
      existingCatalog: false,
      local: false,
      hangCatalog: true,
    );
  });
  testWidgets('pending artwork cannot block a selected stream', (tester) async {
    await _resume(
      tester,
      enabled: true,
      existingCatalog: true,
      local: false,
      hangArtwork: true,
    );
  });
  testWidgets('AniZip failure preserves the playable catalog', (tester) async {
    await _resume(
      tester,
      enabled: true,
      existingCatalog: false,
      failArtwork: true,
      local: false,
    );
  });
}

Future<void> _resume(
  WidgetTester tester, {
  required bool enabled,
  required bool existingCatalog,
  bool failArtwork = false,
  required bool local,
  Episode? originalEpisode,
  bool hangCatalog = false,
  bool hangArtwork = false,
}) async {
  final provider = _Provider(
    failArtwork: failArtwork,
    hangCatalog: hangCatalog,
    hangArtwork: hangArtwork,
  );
  if (originalEpisode != null) provider.episodes[1] = originalEpisode;
  final history = _History();
  PlayerRouteExtra? player;
  final item = MultimediaItem(
    title: 'Show',
    url: 'show',
    posterUrl: '',
    provider: provider.packageName,
    contentType: MultimediaContentType.anime,
    episodes: existingCatalog ? provider.episodes : null,
  );
  final saved = HistoryItem(
    item: item,
    position: 30,
    duration: 100,
    timestamp: 0,
    lastEpisodeUrl: 'show|2',
    episode: 2,
    season: 1,
    episodePosterUrl: 'old-2',
    episodeTitle: originalEpisode?.name,
    episodeServerName: originalEpisode?.serverName,
    episodeServerNumber: originalEpisode?.serverNumber,
  );
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: TextButton(
            onPressed: () {
              final launcher = ProviderScope.containerOf(context)
                  .read(playbackLauncherProvider);
              unawaited(
                local
                    ? launcher.playFromContinueWatching(context, saved)
                    : launcher.play(
                        context,
                        'show|2',
                        baseItem: item,
                        episode: launcher.episodeFromContinueWatching(saved),
                        preselectedSource: const StreamResult(
                          url: 'https://example.test/video.mp4',
                          source: 'direct',
                        ),
                      ),
              );
            },
            child: const Text('resume'),
          ),
        ),
      ),
      GoRoute(
        path: '/player',
        builder: (context, state) {
          player = state.extra! as PlayerRouteExtra;
          return Scaffold(
            body: Column(
              children: [
                const Text('player'),
                if (originalEpisode != null)
                  PlayerTopBar(
                    title: player!.item.title,
                    episodeLabel: formatEpisodeLabel(
                      episode: player!.episode!.episode,
                      isArabic: true,
                      title: player!.episode!.name,
                      serverName: player!.episode!.serverName,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playerSettingsProvider.overrideWith(_Settings.new),
        animeDataSourceSettingsProvider.overrideWith(
          () => _ArtworkSettings(enabled),
        ),
        downloadedFilesProvider.overrideWith(() => _Downloads(local)),
        watchHistoryProvider.overrideWith(() => history),
        extensionManagerProvider.overrideWith(() => _Extensions(provider)),
        activeProviderProvider.overrideWithValue(provider),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('resume'));
  await tester.pumpAndSettle();
  expect(find.text('player'), findsOneWidget);
  expect(provider.catalogCalls, 0);
  expect(provider.artworkCalls, 0);
  final expectedEpisode = !existingCatalog
      ? originalEpisode?.copyWith(posterUrl: 'old-2') ??
            Episode(
              name: '',
              url: 'show|2',
              episode: 2,
              season: 1,
              posterUrl: 'old-2',
            )
      : provider.episodes.last.copyWith(posterUrl: 'source-2');
  if (!existingCatalog) {
    expect(player!.item.episodes!.map((e) => e.posterUrl), ['old-2']);
  } else {
    expect(player!.item.episodes!.map((e) => e.posterUrl), [
      'source-1',
      'source-2',
    ]);
  }
  expect(player!.episode!.posterUrl, expectedEpisode.posterUrl);
  expect(player!.episode!.url, expectedEpisode.url);
  expect(player!.episode!.name, expectedEpisode.name);
  expect(player!.episode!.episode, expectedEpisode.episode);
  expect(player!.episode!.season, expectedEpisode.season);
  expect(player!.episode!.serverName, expectedEpisode.serverName);
  expect(player!.episode!.isFinal, expectedEpisode.isFinal);
  expect(player!.episode!.serverNumber, expectedEpisode.serverNumber);
  if (originalEpisode != null) {
    expect(find.text(originalEpisode.serverName), findsOneWidget);
    expect(history.storedTitle, originalEpisode.serverName);
    expect(history.storedServerName, originalEpisode.serverName);
    expect(history.storedServerNumber, originalEpisode.serverNumber);
  }
  expect(history.opened!.posterUrl, expectedEpisode.posterUrl);
  expect(player!.progressUrl, 'show|2');
  router.pop();
  await tester.pumpAndSettle();
  await tester.pumpWidget(const SizedBox.shrink());
  router.dispose();
}
