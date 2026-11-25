import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/library/presentation/widgets/completed_download_episode_card.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../../support/memory_storage_service.dart';

class _Storage extends MemoryStorageService {
  List<Map<String, dynamic>> snapshot = [];

  @override
  List<Map<String, dynamic>> getWatchHistory() => snapshot;

  @override
  int getEpisodeDuration(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;

  @override
  int getEpisodePosition(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  late Directory artworkRoot;
  final originalPaths = PathProviderPlatform.instance;
  setUpAll(() async {
    artworkRoot = await Directory.systemTemp.createTemp('aw-history-card-');
    PathProviderPlatform.instance = _Paths(artworkRoot.path);
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    await artworkRoot.delete(recursive: true);
  });

  testWidgets(
    'downloaded episode badge follows the latest own-provider history',
    (tester) async {
      const url = 'https://example.test/series';
      final storage = _Storage();
      final matching = <String, dynamic>{
        'url': url,
        'provider': 'Extension A',
        'season': 1,
        'episode': 2,
      };
      final otherProvider = <String, dynamic>{
        ...matching,
        'provider': 'Extension B',
      };
      storage.snapshot = [otherProvider, matching];
      final container = ProviderContainer(
        overrides: [storageServiceProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      final item = DownloadItem(
        task: DownloadTask(
          taskId: 'video-ep2-fixture',
          url: 'https://example.test/video.mp4',
          filename: 'episode.mp4',
        ),
        status: TaskStatus.complete,
        progress: 1,
        item: MultimediaItem(
          title: 'Series',
          url: url,
          posterUrl: '',
          provider: 'Extension A',
        ),
        episode: Episode(
          name: 'Episode 2',
          url: '$url/e2',
          season: 1,
          episode: 2,
        ),
        timestamp: 1,
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CompletedDownloadEpisodeCard(
                item: item,
                onPlay: () {},
                onDelete: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final badge = find.text('آخر مشاهدة');
      expect(badge, findsOneWidget);

      storage.snapshot = [
        otherProvider,
        {...matching, 'episode': 1},
      ];
      container.read(watchHistoryProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(badge, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
