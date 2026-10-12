import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
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

import '../../../support/widget_completion.dart';

class _Settings extends PlayerSettingsNotifier {
  @override
  Future<PlayerSettings> build() async => const PlayerSettings();
}

class _History extends WatchHistory {
  @override
  List<HistoryItem> build() => const [];
  @override
  Future<void> recordOpened(MultimediaItem item, {
    String? lastEpisodeUrl, int? season, int? episode, String? episodeTitle,
    String? episodeServerName, String? episodePosterUrl,
  }) async {}
}

class _Files extends DownloadedFiles {
  _Files(this.file);
  final File file;
  @override
  Map<String, File?> build() => const {};
  @override
  Future<File?> resolveFile(MultimediaItem item, {Episode? episode, String? logicalId}) async => file;
}

class _Extensions extends ExtensionManager {
  _Extensions(this.provider);
  final AnimeWitcherProvider provider;
  @override
  List<AnimeWitcherProvider> build() => [provider];
}

class _OfflineProvider extends AnimeWitcherProvider {
  _OfflineProvider(this.throwOffline);
  final bool throwOffline;
  final pending = Completer<List<Episode>>();
  int catalogCalls = 0;
  @override
  String get packageName => 'offline.playback';
  @override
  String get name => 'Offline playback';
  @override
  String get mainUrl => 'https://example.test';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['ar'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.anime};
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => const {};
  @override
  Future<List<MultimediaItem>> search(String query, {CancelToken? cancelToken}) async => const [];
  @override
  Future<MultimediaItem> getDetails(String url) async => throw StateError('offline');
  @override
  Future<List<StreamResult>> loadStreams(String url) async => throw StateError('offline');
  @override
  Future<List<Episode>> getEpisodes(String url) {
    catalogCalls++;
    if (throwOffline) throw StateError('offline catalog');
    return pending.future;
  }
}

void main() {
  for (final directFile in [false, true]) {
    for (final throwOffline in [false, true]) {
      testWidgets('local playback direct=$directFile offline=$throwOffline opens without catalog dependency', (tester) async {
        final root = (await tester.runAsync(() => Directory.systemTemp.createTemp('aw-offline-play-')))!;
        addTearDown(() => root.delete(recursive: true));
        final file = (await tester.runAsync(() => File('${root.path}/episode.mp4').writeAsBytes([1, 2, 3])))!;
        final provider = _OfflineProvider(throwOffline);
        final episode = Episode(name: 'Saved episode', url: 'episode://saved', episode: 2, season: 1);
        final item = MultimediaItem(
          title: 'Saved show', url: 'show://saved', posterUrl: '',
          contentType: MultimediaContentType.anime, provider: provider.packageName,
        );
        PlayerRouteExtra? opened;
        final router = GoRouter(routes: [
          GoRoute(path: '/', builder: (context, state) => Scaffold(body: TextButton(
            onPressed: () => unawaited(ProviderScope.containerOf(context).read(playbackLauncherProvider).play(
              context, directFile ? file.path : episode.url, baseItem: item, episode: episode,
            )),
            child: const Text('Open saved download'),
          ))),
          GoRoute(path: '/player', builder: (context, state) {
            opened = state.extra! as PlayerRouteExtra;
            return const Scaffold(body: Text('Local player opened'));
          }),
        ]);
        try {
          await tester.pumpWidget(ProviderScope(overrides: [
            playerSettingsProvider.overrideWith(_Settings.new),
            watchHistoryProvider.overrideWith(_History.new),
            downloadedFilesProvider.overrideWith(() => _Files(file)),
            extensionManagerProvider.overrideWith(() => _Extensions(provider)),
            activeProviderProvider.overrideWithValue(provider),
          ], child: MaterialApp.router(routerConfig: router)));
          await pumpUntil(tester, () => find.text('Open saved download').evaluate().isNotEmpty, 'local playback action');
          await tester.tap(find.text('Open saved download'));
          await pumpUntil(tester, () => opened != null, 'local player route without network', timeout: const Duration(seconds: 2));
          expect(provider.catalogCalls, 0);
          expect(opened!.videoUrl, endsWith('/episode.mp4'));
          expect(opened!.progressUrl, episode.url);
          expect(opened!.episode?.url, episode.url);
          expect(opened!.item.episodes?.map((value) => value.url), contains(episode.url));
        } finally {
          if (!provider.pending.isCompleted) provider.pending.complete(const []);
          await tester.pumpWidget(const SizedBox.shrink());
          router.dispose();
        }
      });
    }
  }
}
