import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/providers/episode_sort_provider.dart';
import 'package:animewitcher/core/storage/episode_watch_repository.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/core/utils/download_time_remaining.dart';
import 'package:animewitcher/features/details/presentation/details_controller.dart';
import 'package:animewitcher/features/details/presentation/downloaded_file_provider.dart';
import 'package:animewitcher/features/details/presentation/playback_launcher.dart';
import 'package:animewitcher/features/details/presentation/widgets/download_progress_dialog.dart';
import 'package:animewitcher/features/details/presentation/widgets/episode_card.dart';
import 'package:animewitcher/features/library/presentation/download_progress_v2_provider.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/widgets/downloads_tab.dart';
import 'package:animewitcher/features/player/presentation/player_controller.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_side_panel.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Rows extends DownloadsNotifier {
  _Rows(this.items);
  final List<DownloadItem> items;
  final List<String> paused = [];
  @override
  Future<List<DownloadItem>> build() async => items;
  @override
  Future<void> pauseDownload(String taskId) async => paused.add(taskId);
}

class _Details extends DetailsController {
  _Details(this.item);
  final MultimediaItem item;
  @override
  DetailsState build(String itemUrl) => DetailsState(item: item);
}

class _Player extends PlayerController {
  @override
  PlayerState build() => const PlayerState(activeEpisodeUrl: 'episode://1');
  @override
  String? get currentEpisodeUrl => 'episode://1';
}

class _History implements HistoryRepository {
  @override
  List<HistoryItem> getWatchHistory() => const [];
  @override
  int getEpisodePosition(String url, {String? mainUrl, int? season, int? episode}) => 0;
  @override
  int getEpisodeDuration(String url, {String? mainUrl, int? season, int? episode}) => 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Watch implements EpisodeWatchRepository {
  @override
  bool? getExplicitState(String mainUrl, Episode episode) => null;
  @override
  bool isWatched(String mainUrl, Episode episode) => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sort extends EpisodeSortAscendingNotifier {
  @override
  bool build() => true;
}

class _Files extends DownloadedFiles {
  _Files({this.byLogicalId = const {}, this.newest, this.cached});
  final Map<String, File> byLogicalId;
  final File? newest;
  final File? cached;
  @override
  Map<String, File?> build() => {'episode://1': cached};
  @override
  Future<void> checkFile(MultimediaItem item, {Episode? episode}) async {}
  // An extra optional argument is valid on an override of the existing API.
  // The current production caller still compiles, but loses the selected row.
  @override
  Future<File?> resolveFile(MultimediaItem item, {Episode? episode, String? logicalId}) async =>
      logicalId == null ? newest : byLogicalId[logicalId];
}

class _Playback extends PlaybackLauncher {
  _Playback(super.ref);
  final List<String> played = [];
  @override
  Future<void> play(BuildContext context, String url, {
    required MultimediaItem baseItem, MultimediaItem? detailedItem, Episode? episode,
    StreamResult? preselectedSource, bool loadEpisodeArtwork = false,
  }) async => played.add(url);
}

final _episode = Episode(name: 'Episode 1', url: 'episode://1', episode: 1);
final _show = MultimediaItem(
  title: 'Variant show', url: 'anime://variants', posterUrl: '',
  contentType: MultimediaContentType.anime, episodes: [_episode],
);

DownloadItem _row(String logical, {TaskStatus status = TaskStatus.running, int timestamp = 1}) =>
    DownloadItem(
      task: DownloadTask(taskId: 'task-$logical', url: 'https://example.test/$logical', filename: '$logical.mp4'),
      status: status, progress: status == TaskStatus.complete ? 1 : .4,
      item: _show, episode: _episode, logicalId: logical,
      trackingUrl: _episode.url, timestamp: timestamp,
    );

Widget _app(Widget home) => MaterialApp(
  locale: const Locale('ar'), localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales, home: Scaffold(body: home),
);

void main() {
  for (final caller in ['episode', 'player']) {
    for (final otherStatus in [TaskStatus.running, TaskStatus.complete]) {
      testWidgets('$caller opens the selected active logical variant beside $otherStatus', (tester) async {
        final selected = _row('selected');
        final rows = _Rows([selected, _row('other', status: otherStatus)]);
        final map = <String, DownloadProgressData>{
          for (final row in rows.items) row.logicalId!: DownloadProgressData(
            taskId: row.id, progress: row.progress, networkSpeed: -1,
            timeRemaining: Duration.zero, status: row.status,
          ),
        };
        final container = ProviderContainer(overrides: [
          downloadsProvider.overrideWith(() => rows),
          downloadProgressProvider.overrideWithValue(map),
          downloadedFilesProvider.overrideWith(() => _Files()),
          detailsControllerProvider.overrideWith(() => _Details(_show)),
          playerControllerProvider.overrideWith(_Player.new),
          historyRepositoryProvider.overrideWithValue(_History()),
          episodeWatchRepositoryProvider.overrideWithValue(_Watch()),
          episodeSortAscendingProvider.overrideWith(_Sort.new),
        ]);
        addTearDown(container.dispose);
        await container.read(downloadsProvider.future);
        await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: _app(caller == 'episode'
              ? EpisodeCard(episode: _episode, parentItem: _show)
              : PlayerEpisodesPanel(item: _show, onClose: () {})),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('جارٍ التنزيل'));
        await tester.pumpAndSettle();
        expect(find.byType(DownloadProgressDialog), findsOneWidget);
        expect(tester.widget<DownloadProgressDialog>(find.byType(DownloadProgressDialog)).trackingUrl, 'selected');
        await tester.tap(find.text('إيقاف مؤقت'));
        await tester.pump();
        expect(rows.paused, ['task-selected']);
      });
    }
  }

  testWidgets('completed Downloads row plays its selected variant instead of newest file', (tester) async {
    final root = (await tester.runAsync(() => Directory.systemTemp.createTemp('aw-ui-variants-')))!;
    addTearDown(() => root.delete(recursive: true));
    final files = (await tester.runAsync(() async => [
      await File('${root.path}/selected.mp4').writeAsBytes([1]),
      await File('${root.path}/newest.mp4').writeAsBytes([2]),
    ]))!;
    final rows = _Rows([
      _row('selected', status: TaskStatus.complete, timestamp: 1),
      _row('other', status: TaskStatus.complete, timestamp: 2),
    ]);
    late _Playback playback;
    final container = ProviderContainer(overrides: [
      downloadsProvider.overrideWith(() => rows),
      downloadProgressProvider.overrideWithValue(const {}),
      downloadedFilesProvider.overrideWith(() => _Files(
        byLogicalId: {'selected': files.first, 'other': files.last}, newest: files.last,
      )),
      playbackLauncherProvider.overrideWith((ref) => playback = _Playback(ref)),
      episodeSortAscendingProvider.overrideWith(_Sort.new),
      historyRepositoryProvider.overrideWithValue(_History()),
      episodeWatchRepositoryProvider.overrideWithValue(_Watch()),
    ]);
    addTearDown(container.dispose);
    await container.read(downloadsProvider.future);
    container.read(playbackLauncherProvider);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: _app(const DownloadsTab())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المكتملة'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Variant show'));
    await tester.pumpAndSettle();
    final selected = find.byKey(const ValueKey('task-selected'));
    expect(selected, findsOneWidget);
    await tester.tap(selected);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(playback.played, [files.first.path]);
  });
}
