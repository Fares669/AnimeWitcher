import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/utils/download_progress_data.dart';
import 'package:animewitcher/features/library/presentation/download_progress_v2_provider.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:animewitcher/features/details/presentation/details_controller.dart';
import 'package:animewitcher/features/details/presentation/downloaded_file_provider.dart';
import 'package:animewitcher/features/details/presentation/widgets/episode_card.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/memory_storage_service.dart';

class _Storage extends MemoryStorageService {
  @override
  String? getString(String key) => null;
  @override
  List<Map<String, dynamic>> getWatchHistory() => [];
  @override
  int getEpisodePosition(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;
  @override
  int getEpisodeDuration(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;
}

class _Files extends DownloadedFiles {
  int checks = 0;
  @override
  Map<String, File?> build() => {};
  @override
  Future<void> checkFile(MultimediaItem item, {Episode? episode}) async {
    checks++;
  }

  void publish(String key, File? file) => state = {...state, key: file};
}

class _Downloads extends DownloadsNotifier {
  @override
  Future<List<DownloadItem>> build() async => [];
  void publish(DownloadItem active) => state = AsyncData([active]);
}

final _testProgressProvider =
    NotifierProvider<_ProgressState, Map<String, DownloadProgressData>>(
      _ProgressState.new,
    );

class _ProgressState extends Notifier<Map<String, DownloadProgressData>> {
  @override
  Map<String, DownloadProgressData> build() => const {};

  void publish({
    required String key,
    required String taskId,
    required double progress,
    TaskStatus status = TaskStatus.running,
  }) {
    state = {
      ...state,
      key: DownloadProgressData(
        taskId: taskId,
        progress: progress,
        status: status,
      ),
    };
  }
}

class _History extends WatchHistory {
  @override
  List<HistoryItem> build() => [];
}

class _Details extends DetailsController {
  @override
  DetailsState build(String itemUrl) => const DetailsState();
}

void main() {
  testWidgets('another episode file result does not rebuild this card', (
    tester,
  ) async {
    final files = _Files();
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(_Storage()),
        downloadsProvider.overrideWith(_Downloads.new),
        watchHistoryProvider.overrideWith(_History.new),
        downloadedFilesProvider.overrideWith(() => files),
        detailsControllerProvider.overrideWith2((_) => _Details()),
      ],
    );
    addTearDown(container.dispose);
    final item = MultimediaItem(title: 'Test', url: 'series', posterUrl: '');
    final episode = Episode(
      name: 'Episode 1',
      url: 'episode-1',
      season: 1,
      episode: 1,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: EpisodeCard(episode: episode, parentItem: item),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    var builds = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is EpisodeCard) builds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    files.publish('another-episode', null);
    await tester.pump();
    expect(builds, 0);
    files.publish(
      downloadedFileKey(item, episode: episode),
      File('/test/video.mp4'),
    );
    await tester.pump();
    expect(builds, 1);
    expect(files.checks, 1);
    expect(tester.takeException(), isNull);
    debugOnRebuildDirtyWidget = null;
  });

  testWidgets('only current owned native progress updates an episode card', (
    tester,
  ) async {
    final downloads = _Downloads();
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(_Storage()),
        downloadsProvider.overrideWith(() => downloads),
        watchHistoryProvider.overrideWith(_History.new),
        downloadedFilesProvider.overrideWith(_Files.new),
        detailsControllerProvider.overrideWith2((_) => _Details()),
        downloadProgressProvider.overrideWith(
          (ref) => ref.watch(_testProgressProvider),
        ),
      ],
    );
    addTearDown(container.dispose);
    final item = MultimediaItem(title: 'Test', url: 'series', posterUrl: '');
    final episode = Episode(name: 'Episode 1', url: 'episode-1', episode: 1);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: EpisodeCard(episode: episode, parentItem: item),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    downloads.publish(
      DownloadItem(
        task: DownloadTask(
          taskId: 'generation-new',
          url: 'https://example.test/video.mp4',
          filename: 'video.mp4',
        ),
        item: item,
        episode: episode,
        trackingUrl: episode.url,
        logicalId: 'current',
        progress: .25,
        status: TaskStatus.running,
        timestamp: 0,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('25%'), findsOneWidget);

    var builds = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is EpisodeCard) builds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    final progress = container.read(_testProgressProvider.notifier);
    progress.publish(key: 'other', taskId: 'generation-other', progress: .81);
    await tester.pump();
    progress.publish(key: 'current', taskId: 'generation-old', progress: .91);
    await tester.pump();
    expect(builds, 0);
    expect(find.text('25%'), findsOneWidget);

    progress.publish(key: 'current', taskId: 'generation-new', progress: .42);
    await tester.pump();
    expect(builds, 1);
    expect(find.text('42%'), findsOneWidget);
    progress.publish(
      key: 'current',
      taskId: 'generation-new',
      progress: .42,
      status: TaskStatus.paused,
    );
    await tester.pump();
    expect(builds, 2);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(find.text('42%'), findsNothing);
    expect(tester.takeException(), isNull);
    debugOnRebuildDirtyWidget = null;
  });
}
