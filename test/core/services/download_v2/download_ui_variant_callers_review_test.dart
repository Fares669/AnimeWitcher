import '../../../support/widget_completion.dart';
import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import '../../../support/manga_image_fixtures.dart';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/providers/episode_sort_provider.dart';
import 'package:animewitcher/core/storage/episode_watch_repository.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/core/utils/download_time_remaining.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/features/library/presentation/widgets/segmented_download_progress.dart';
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
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

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
  final List<MultimediaItem> playedItems = [];
  @override
  Future<void> play(BuildContext context, String url, {
    required MultimediaItem baseItem, MultimediaItem? detailedItem, Episode? episode,
    StreamResult? preselectedSource, bool loadEpisodeArtwork = false,
  }) async {
    played.add(url);
    playedItems.add(detailedItem ?? baseItem);
  }
}

final _episode = Episode(name: 'Episode 1', url: 'episode://1', episode: 1);
final _show = MultimediaItem(
  title: 'Variant show', url: 'anime://variants', posterUrl: '',
  contentType: MultimediaContentType.anime, episodes: [_episode],
);

DownloadItem _row(String logical, {TaskStatus status = TaskStatus.running, int timestamp = 1, Episode? episode}) =>
    DownloadItem(
      task: DownloadTask(taskId: 'task-$logical', url: 'https://example.test/$logical', filename: '$logical.mp4'),
      status: status, progress: status == TaskStatus.complete ? 1 : .4,
      item: _show, episode: episode ?? _episode, logicalId: logical,
      trackingUrl: episode?.url ?? _episode.url, timestamp: timestamp,
    );

Widget _app(Widget home) => MaterialApp(
  locale: const Locale('ar'), localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales, home: Scaffold(body: home),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalPaths = PathProviderPlatform.instance;
  late Directory cacheRoot;
  setUpAll(() { cacheRoot = Directory.systemTemp.createTempSync('aw-ui-cache-'); });
  setUp(() { PathProviderPlatform.instance = _Paths(cacheRoot.path); });
  tearDown(() { PathProviderPlatform.instance = originalPaths; });
  tearDownAll(() => cacheRoot.delete(recursive: true));

  for (final manga in [true, false]) {
    testWidgets('${manga ? 'Manga pages' : 'video bytes'} agree with the downloads tile bar', (tester) async {
      await tester.runAsync(() async {
        await DefaultCacheManager().getFileFromCache('page-progress-fixture-lifecycle');
      });
      final progress = manga ? 12 / 23 : .4;
      final row = DownloadItem(
        task: DownloadTask(taskId: 'progress-tile', url: 'https://example.test/tile', filename: 'tile'),
        status: TaskStatus.running, progress: progress, item: _show,
        mediaKind: manga ? DownloadMediaKind.mangaChapter : DownloadMediaKind.videoEpisode,
        logicalId: 'progress-tile', timestamp: 1,
        completedPages: manga ? 12 : null, totalPages: manga ? 23 : null,
      );
      final container = ProviderContainer(overrides: [
        downloadsProvider.overrideWith(() => _Rows([row])),
        downloadProgressProvider.overrideWithValue({
          'progress-tile': DownloadProgressData(
            taskId: row.id, progress: progress, networkSpeed: -1,
            timeRemaining: Duration.zero, status: TaskStatus.running, totalSize: 1000000,
            completedPages: manga ? 12 : null, totalPages: manga ? 23 : null,
          ),
        }),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(container: container, child: _app(const DownloadsTab())));
      final label = manga ? '12/23 صفحة' : '0.4 MB / 1.0 MB';
      await pumpUntil(tester, () => find.text(label).evaluate().isNotEmpty, 'download tile units');
      expect(find.text(label), findsOneWidget);
      expect(find.text(manga ? '52%' : '40%'), findsOneWidget);
      expect(tester.widget<SegmentedDownloadProgress>(find.byType(SegmentedDownloadProgress)).value, progress);
      if (manga) expect(find.textContaining(' MB'), findsNothing);
    });
  }

  for (final caller in ['episode', 'episode-key', 'player']) {
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
          downloadedFilesProvider.overrideWith(() => _Files(
            cached: otherStatus == TaskStatus.complete ? File('/tmp/retained-complete.mp4') : null,
          )),
          detailsControllerProvider.overrideWith(() => _Details(_show)),
          playerControllerProvider.overrideWith(_Player.new),
          historyRepositoryProvider.overrideWithValue(_History()),
          episodeWatchRepositoryProvider.overrideWithValue(_Watch()),
          episodeSortAscendingProvider.overrideWith(_Sort.new),
        ]);
        addTearDown(container.dispose);
        await pumpUntilFuture(tester, container.read(downloadsProvider.future), '$caller download rows');
        await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: _app(caller.startsWith('episode')
              ? EpisodeCard(episode: _episode, parentItem: _show)
              : PlayerEpisodesPanel(item: _show, onClose: () {})),
        ));
        await pumpUntil(tester, () => find.byTooltip('جارٍ التنزيل').evaluate().isNotEmpty, '$caller active download control');
        if (caller == 'episode-key') {
          final bodyFocus = tester.widget<Focus>(find.byWidgetPredicate(
            (widget) => widget is Focus && widget.focusNode?.debugLabel == 'ep_body',
          ));
          bodyFocus.focusNode!.requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.f10);
        } else {
          await tester.tap(find.byTooltip('جارٍ التنزيل'));
        }
        await pumpUntil(tester, () => find.byType(Dialog).evaluate().isNotEmpty, '$caller selected variant dialog');
        expect(find.byType(DownloadProgressDialog), findsOneWidget);
        expect(tester.widget<DownloadProgressDialog>(find.byType(DownloadProgressDialog)).trackingUrl, 'selected');
        await tester.tap(find.text('إيقاف مؤقت'));
        await tester.pump();
        expect(rows.paused, ['task-selected']);
      });
    }
  }

  testWidgets('completed group uses its permanent poster after UI recreation offline', (tester) async {
    // The transient first frame still renders the existing network fallback.
    // Initialize its shared cache lifecycle on the real loop, without assuming
    // that disposing a singleton recreates it for subsequent widget tests.
    await tester.runAsync(() async {
      await DefaultCacheManager().getFileFromCache('offline-poster-fixture-lifecycle');
    });
    final key = sha256.convert(utf8.encode('retained-poster')).toString();
    final saved = File('${cacheRoot.path}/download_artwork_v2/$key/poster.img');
    await tester.runAsync(() async {
      await saved.parent.create(recursive: true);
      await saved.writeAsBytes(tinyMangaJpeg);
    });
    final rows = _Rows([_row('retained-poster', status: TaskStatus.complete)]);
    final container = ProviderContainer(overrides: [
      downloadsProvider.overrideWith(() => rows),
      downloadProgressProvider.overrideWithValue(const {}),
      episodeSortAscendingProvider.overrideWith(_Sort.new),
    ]);
    addTearDown(container.dispose);
    for (var recreation = 0; recreation < 2; recreation++) {
      await tester.pumpWidget(UncontrolledProviderScope(container: container, child: _app(const DownloadsTab())));
      await pumpUntil(tester, () => find.text('المكتملة').evaluate().isNotEmpty, 'offline completed tab');
      await tester.tap(find.text('المكتملة'));
      await pumpUntil(tester, () => find.text('Variant show').hitTestable().evaluate().isNotEmpty, 'visible offline completed show');
      bool usesSavedPoster() => tester.widgetList<Image>(find.byType(Image)).any((widget) {
        final provider = widget.image;
        final image = provider is ResizeImage ? provider.imageProvider : provider;
        return image is FileImage && image.file.path == saved.path;
      });
      await pumpUntil(tester, usesSavedPoster, 'durable poster file after UI recreation');
      expect(usesSavedPoster(), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

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
      _row('adjacent', status: TaskStatus.complete, timestamp: 3,
        episode: Episode(name: 'Episode 2', url: 'episode://2', episode: 2)),
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
    await pumpUntilFuture(tester, container.read(downloadsProvider.future), 'completed variant rows');
    container.read(playbackLauncherProvider);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: _app(const DownloadsTab())));
    await pumpUntil(tester, () => find.text('المكتملة').evaluate().isNotEmpty, 'completed downloads tab');
    await tester.tap(find.text('المكتملة'));
    await pumpUntil(tester, () => find.text('Variant show').hitTestable().evaluate().isNotEmpty, 'visible completed show group');
    await tester.tap(find.text('Variant show'));
    await pumpUntil(tester, () => find.byKey(const ValueKey('task-selected')).evaluate().isNotEmpty, 'selected completed variant card');
    final selected = find.byKey(const ValueKey('task-selected'));
    expect(selected, findsOneWidget);
    await tester.ensureVisible(selected);
    await pumpUntil(tester, () => selected.hitTestable().evaluate().isNotEmpty, 'visible selected completed card');
    await tester.tap(selected);
    await pumpUntil(tester, () => playback.played.isNotEmpty, 'selected completed playback');
    expect(playback.played, [files.first.path]);
    expect(playback.playedItems.single.episodes?.map((value) => value.url), containsAll(['episode://1', 'episode://2']));
  });
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}
