import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_concurrency.dart';
import 'package:animewitcher/core/services/download_service.dart';
import 'package:animewitcher/core/utils/download_cleanup.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/widgets/downloads_tab.dart';
import 'package:animewitcher/shared/widgets/underline_segment_tabs.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../support/test_fonts.dart';

MultimediaItem _blackTorch() {
  return MultimediaItem(
    title: 'Black Torch',
    url: 'https://animewitcher.test/black-torch',
    posterUrl: '',
    contentType: MultimediaContentType.anime,
  );
}

Episode _episode9() {
  return Episode(
    name: 'الحلقة 9',
    url: 'https://animewitcher.test/black-torch/9',
    episode: 9,
    serverName: 'الحلقة 9',
  );
}

DownloadTask _task({
  required String taskId,
  required String filename,
  String directory = 'AnimeWitcher/Downloads/Black Torch',
  String metaData = 'https://animewitcher.test/black-torch/9',
}) {
  return DownloadTask(
    taskId: taskId,
    url: 'https://cdn.test/black-torch-9.mp4',
    filename: filename,
    directory: directory,
    metaData: metaData,
  );
}

DownloadItem _item({
  required String taskId,
  required int timestamp,
  String filename = 'الحلقة 9.mp4',
  TaskStatus status = TaskStatus.complete,
  String metaData = 'https://animewitcher.test/black-torch/9',
  Episode? episode,
}) {
  return DownloadItem(
    task: _task(taskId: taskId, filename: filename, metaData: metaData),
    status: status,
    progress: status == TaskStatus.complete ? 1.0 : 0.4,
    item: _blackTorch(),
    episode: episode ?? _episode9(),
    timestamp: timestamp,
  );
}

class _StubDownloadsNotifier extends DownloadsNotifier {
  _StubDownloadsNotifier(this._items);

  final List<DownloadItem> _items;

  @override
  Future<List<DownloadItem>> build() async => _items;
}

Widget _downloadsApp(
  List<DownloadItem> items, {
  TextDirection? shellDirection,
}) {
  Widget home = const Scaffold(
    body: RepaintBoundary(
      key: ValueKey('downloads-tab-root'),
      child: DownloadsTab(),
    ),
  );
  if (shellDirection != null) {
    home = Directionality(textDirection: shellDirection, child: home);
  }
  return ProviderScope(
    overrides: [
      downloadsProvider.overrideWith(() => _StubDownloadsNotifier(items)),
    ],
    child: MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('delete uses the task file path, not reconstructed labels', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('aw_dl_path_');
      addTearDown(() => root.delete(recursive: true));

      final series = Directory(
        p.join(root.path, 'AnimeWitcher', 'Downloads', 'Black Torch'),
      );
      final season = Directory(p.join(series.path, 'Season 1'));
      await season.create(recursive: true);

      final taskFile = File(p.join(season.path, 'الحلقة 9 (1080p).mp4'));
      await taskFile.writeAsBytes(List<int>.filled(32, 1));
      final reconstructed = File(p.join(series.path, 'الحلقة 9.mp4'));
      await reconstructed.writeAsBytes(List<int>.filled(32, 2));

      var usedTaskPath = false;
      var usedRawPath = false;
      var usedLabels = false;
      final resolved = await resolveDownloadFileToDelete(
        fromTask: () async {
          usedTaskPath = true;
          return taskFile;
        },
        taskFilePath: () async {
          usedRawPath = true;
          return reconstructed.path;
        },
        fromLabels: () async {
          usedLabels = true;
          return reconstructed;
        },
      );

      expect(resolved!.path, taskFile.path);
      expect(usedTaskPath, isTrue);
      expect(usedRawPath, isFalse);
      expect(usedLabels, isFalse);

      await deleteDownloadedVideo(resolved);

      expect(await taskFile.exists(), isFalse);
      expect(await reconstructed.exists(), isTrue);
      expect(await series.exists(), isTrue);
    });
  });

  testWidgets('resolve falls back to task.filePath then reconstructed labels', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('aw_dl_resolve_');
      addTearDown(() => root.delete(recursive: true));
      final series = Directory(
        p.join(root.path, 'AnimeWitcher', 'Downloads', 'Black Torch'),
      );
      await series.create(recursive: true);
      final pathFile = File(p.join(series.path, 'الحلقة 9 (1080p).mp4'));
      await pathFile.writeAsBytes(List<int>.filled(8, 1));
      final reconstructed = File(p.join(series.path, 'الحلقة 9.mp4'));
      await reconstructed.writeAsBytes(List<int>.filled(8, 2));

      var usedLabels = false;
      final fromPath = await resolveDownloadFileToDelete(
        fromTask: () async => null,
        taskFilePath: () async => pathFile.path,
        fromLabels: () async {
          usedLabels = true;
          return reconstructed;
        },
      );
      expect(fromPath!.path, pathFile.path);
      expect(usedLabels, isFalse);

      final fromLabels = await resolveDownloadFileToDelete(
        fromTask: () async => null,
        taskFilePath: () async => null,
        fromLabels: () async => reconstructed,
      );
      expect(fromLabels!.path, reconstructed.path);
    });
  });

  testWidgets(
    'deleting the last episode removes the series folder leftover files and all',
    (tester) async {
      await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('aw_dl_folder_');
        addTearDown(() => root.delete(recursive: true));

        final downloadsRoot = Directory(
          p.join(root.path, 'AnimeWitcher', 'Downloads'),
        );
        final series = Directory(p.join(downloadsRoot.path, 'Black Torch'));
        final season = Directory(p.join(series.path, 'Season 1'));
        await season.create(recursive: true);

        final video = File(p.join(season.path, 'الحلقة 9.mp4'));
        await video.writeAsBytes(List<int>.filled(32, 1));
        await File(
          p.join(season.path, '${p.basename(video.path)}.part'),
        ).writeAsBytes([1]);
        await File(
          p.join(season.path, '${p.basename(video.path)}.tmp'),
        ).writeAsBytes([1]);
        await File(
          p.join(season.path, '${p.basename(video.path)}.download'),
        ).writeAsBytes([1]);
        await File(p.join(season.path, 'thumb.jpg')).writeAsBytes([1]);
        await Directory(p.join(series.path, 'Season 2')).create();

        final otherSeries = Directory(p.join(downloadsRoot.path, 'Bleach'));
        await otherSeries.create();
        final otherVideo = File(p.join(otherSeries.path, 'الحلقة 1.mp4'));
        await otherVideo.writeAsBytes(List<int>.filled(32, 3));

        await deleteDownloadedVideo(video);

        expect(await video.exists(), isFalse);
        expect(await series.exists(), isFalse);
        expect(await downloadsRoot.exists(), isTrue);
        expect(await otherSeries.exists(), isTrue);
        expect(await otherVideo.exists(), isTrue);
      });
    },
  );

  testWidgets('delete also removes sibling .part .tmp .download temps', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('aw_dl_temps_');
      addTearDown(() => root.delete(recursive: true));
      final series = Directory(
        p.join(root.path, 'AnimeWitcher', 'Downloads', 'Keep Me'),
      );
      await series.create(recursive: true);
      final video = File(p.join(series.path, 'keep.mp4'));
      await video.writeAsBytes(List<int>.filled(32, 1));
      final other = File(p.join(series.path, 'other.mp4'));
      await other.writeAsBytes(List<int>.filled(32, 2));
      final part = File(p.join(series.path, 'keep.mp4.part'));
      final tmp = File(p.join(series.path, 'keep.mp4.tmp'));
      final download = File(p.join(series.path, 'keep.mp4.download'));
      await part.writeAsBytes([1]);
      await tmp.writeAsBytes([1]);
      await download.writeAsBytes([1]);

      await deleteDownloadedVideo(video);

      expect(await video.exists(), isFalse);
      expect(await part.exists(), isFalse);
      expect(await tmp.exists(), isFalse);
      expect(await download.exists(), isFalse);
      expect(await other.exists(), isTrue);
      expect(await series.exists(), isTrue);
    });
  });

  testWidgets(
    'two complete records for the same episode collapse to one UI row',
    (tester) async {
      final older = _item(taskId: 'old-complete', timestamp: 100);
      final newer = _item(taskId: 'new-complete', timestamp: 200);
      expect(older.task.taskId, isNot(newer.task.taskId));
      expect(downloadTrackingUrl(older.task), downloadTrackingUrl(newer.task));
      expect(downloadsPointAtSameTarget(older, newer), isTrue);
      expect(collapseDuplicateDownloads([older, newer]).visible, hasLength(1));
      expect(
        collapseDuplicateDownloads([older, newer]).visible.single.id,
        'new-complete',
      );
      expect(
        collapseDuplicateDownloads([older, newer]).extraCompleteRecords,
        hasLength(1),
      );
      expect(
        collapseDuplicateDownloads([
          older,
          newer,
        ]).extraCompleteRecords.single.id,
        'old-complete',
      );

      await tester.pumpWidget(_downloadsApp([older, newer]));
      await tester.pump();

      expect(find.text('المكتملة'), findsOneWidget);
      await tester.tap(find.text('المكتملة'));
      await tester.pumpAndSettle();

      expect(find.text('الحلقة 9'), findsOneWidget);
      expect(find.text('Black Torch'), findsOneWidget);
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.byIcon(Icons.play_circle_fill_rounded), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);
    },
  );

  test('canonical identity is task metaData / episode.url, not taskId', () {
    final a = _item(taskId: 'task-a', timestamp: 1);
    final b = _item(taskId: 'task-b', timestamp: 2);
    expect(
      downloadTrackingUrl(a.task),
      'https://animewitcher.test/black-torch/9',
    );
    expect(downloadIdentityKey(a.item, a.episode), a.episode!.url);
    expect(downloadsPointAtSameTarget(a, b), isTrue);

    final other = DownloadItem(
      task: _task(
        taskId: 'task-c',
        filename: 'الحلقة 10.mp4',
        metaData: 'https://animewitcher.test/black-torch/10',
      ),
      status: TaskStatus.complete,
      progress: 1.0,
      item: _blackTorch(),
      episode: Episode(
        name: 'الحلقة 10',
        url: 'https://animewitcher.test/black-torch/10',
        episode: 10,
        serverName: 'الحلقة 10',
      ),
      timestamp: 3,
    );
    expect(downloadsPointAtSameTarget(a, other), isFalse);
  });

  test('complete records skip cancel; in-progress records cancel', () {
    expect(shouldCancelDownload(TaskStatus.complete), isFalse);
    expect(shouldCancelDownload(TaskStatus.running), isTrue);
    expect(shouldCancelDownload(TaskStatus.enqueued), isTrue);
    expect(shouldCancelDownload(TaskStatus.paused), isTrue);
  });

  test('startDownload reuses a complete record when the file exists', () {
    expect(
      decideCompleteDownloadAction(hasCompleteRecord: true, fileExists: true),
      CompleteDownloadAction.reuse,
    );
    expect(
      decideCompleteDownloadAction(hasCompleteRecord: true, fileExists: false),
      CompleteDownloadAction.dropAndEnqueue,
    );
    expect(
      decideCompleteDownloadAction(hasCompleteRecord: false, fileExists: false),
      CompleteDownloadAction.enqueue,
    );
  });

  testWidgets('waiting overflow keeps في الانتظار without restyling the row', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => '/tmp',
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      ),
    );

    await tester.runAsync(TestFonts.loadWalkthroughFonts);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final runningItem = MultimediaItem(
      title: 'Black Torch',
      url: 'https://animewitcher.test/black-torch',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
      tmdbId: 3,
    );
    final waitingItem = MultimediaItem(
      title: 'Black Torch',
      url: 'https://animewitcher.test/black-torch',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
      tmdbId: 4,
    );
    final running = DownloadItem(
      task: _task(
        taskId: 'ep3',
        filename: 'الحلقة 3.mp4',
        metaData: 'https://animewitcher.test/black-torch/3',
      ),
      status: TaskStatus.running,
      progress: 0.18,
      item: runningItem,
      episode: Episode(
        name: 'الحلقة 3',
        url: 'https://animewitcher.test/black-torch/3',
        episode: 3,
        serverName: 'الحلقة 3',
      ),
      timestamp: 30,
    );
    final waiting = DownloadItem(
      task: _task(
        taskId: 'ep4',
        filename: 'الحلقة 4.mp4',
        metaData: 'https://animewitcher.test/black-torch/4',
      ),
      status: TaskStatus.enqueued,
      progress: 0,
      item: waitingItem,
      episode: Episode(
        name: 'الحلقة 4',
        url: 'https://animewitcher.test/black-torch/4',
        episode: 4,
        serverName: 'الحلقة 4',
      ),
      timestamp: 40,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadsProvider.overrideWith(
            () => _StubDownloadsNotifier([waiting, running]),
          ),
          downloadProgressProvider.overrideWithValue({
            running.task.metaData: DownloadProgressData(
              taskId: 'ep3',
              progress: 0.18,
              networkSpeed: 0.127,
              timeRemaining: const Duration(minutes: 39, seconds: 44),
              status: TaskStatus.running,
              totalSize: 365400000,
            ),
            waiting.task.metaData: DownloadProgressData(
              taskId: 'ep4',
              progress: 0,
              networkSpeed: 0,
              timeRemaining: Duration.zero,
              status: TaskStatus.enqueued,
              totalSize: 462200000,
            ),
          }),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: 'NotoSansArabic',
            scaffoldBackgroundColor: Colors.black,
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFFEEC60A),
              surface: Color(0xFF1A1A1A),
              onSurface: Color(0xFFE5E7EB),
            ),
          ),
          home: const Scaffold(
            body: RepaintBoundary(
              key: ValueKey('downloads-waiting-row'),
              child: DownloadsTab(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('التنزيلات'), findsWidgets);
    expect(find.text('المكتملة'), findsOneWidget);
    expect(find.text('جارٍ التنزيل...'), findsOneWidget);
    expect(find.text('في الانتظار...'), findsOneWidget);
    expect(find.text('قيد الانتظار'), findsNothing);
    expect(find.text('متوقف مؤقتاً'), findsNothing);
    expect(find.byIcon(Icons.pause_rounded), findsNWidgets(2));
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    expect(find.byIcon(Icons.drag_handle_rounded), findsNWidgets(2));
    expect(find.byType(ExpansionTile), findsNothing);

    final artifacts = Directory('/opt/cursor/artifacts');
    if (!artifacts.existsSync()) return;

    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('downloads-waiting-row')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '${artifacts.path}/downloads_waiting_in_app.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });

  testWidgets('active tab keeps one ungrouped card per episode', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => '/tmp',
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      ),
    );

    final show = MultimediaItem(
      title: 'Kuroneko',
      url: 'https://animewitcher.test/kuro',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
      tmdbId: 20,
    );
    DownloadItem episode(int n, TaskStatus status) {
      return DownloadItem(
        task: _task(
          taskId: 'ep$n',
          filename: 'الحلقة $n.mp4',
          metaData: 'https://animewitcher.test/kuro/$n',
        ),
        status: status,
        progress: status == TaskStatus.complete ? 1 : 0.2,
        item: show,
        episode: Episode(
          name: 'الحلقة $n',
          url: 'https://animewitcher.test/kuro/$n',
          episode: n,
          serverName: 'الحلقة $n',
        ),
        timestamp: n * 10,
      );
    }

    await tester.pumpWidget(
      _downloadsApp([
        episode(20, TaskStatus.running),
        episode(21, TaskStatus.enqueued),
      ]),
    );
    await tester.pump();

    expect(find.text('الحلقة 20'), findsOneWidget);
    expect(find.text('الحلقة 21'), findsOneWidget);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(find.byIcon(Icons.drag_handle_rounded), findsNWidgets(2));
    expect(find.byType(FilterStyleTabBar), findsOneWidget);

    final artifacts = Directory('/opt/cursor/artifacts');
    if (artifacts.existsSync()) {
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('downloads-tab-root')),
        );
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '${artifacts.path}/downloads_active_ungrouped.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
  });

  testWidgets('completed tab still groups multiple episodes of one anime', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => '/tmp',
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      ),
    );

    final show = MultimediaItem(
      title: 'Bleach',
      url: 'https://animewitcher.test/bleach',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
      tmdbId: 7,
    );
    DownloadItem episode(int n) {
      return DownloadItem(
        task: _task(
          taskId: 'bleach-$n',
          filename: 'الحلقة $n.mp4',
          metaData: 'https://animewitcher.test/bleach/$n',
        ),
        status: TaskStatus.complete,
        progress: 1,
        item: show,
        episode: Episode(
          name: 'الحلقة $n',
          url: 'https://animewitcher.test/bleach/$n',
          episode: n,
          serverName: 'الحلقة $n',
        ),
        timestamp: n,
      );
    }

    await tester.pumpWidget(_downloadsApp([episode(1), episode(2)]));
    await tester.pump();
    await tester.tap(find.text('المكتملة'));
    await tester.pumpAndSettle();

    expect(find.byType(ExpansionTile), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);
    expect(find.text('Bleach'), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.byType(TabBarView))),
      TextDirection.rtl,
    );
    expect(
      Directionality.of(tester.element(find.byType(ExpansionTile))),
      TextDirection.ltr,
    );

    final artifacts = Directory('/opt/cursor/artifacts');
    if (artifacts.existsSync()) {
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('downloads-tab-root')),
        );
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '${artifacts.path}/downloads_completed_grouped.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
  });

  testWidgets('tab swipe follows RTL like المواسم and الإحصائيات', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => '/tmp',
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      ),
    );

    final show = MultimediaItem(
      title: 'Kuroneko',
      url: 'https://animewitcher.test/kuro',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
      tmdbId: 20,
    );
    DownloadItem episode(int n, TaskStatus status) {
      return DownloadItem(
        task: _task(
          taskId: 'ep$n',
          filename: 'الحلقة $n.mp4',
          metaData: 'https://animewitcher.test/kuro/$n',
        ),
        status: status,
        progress: status == TaskStatus.complete ? 1 : 0.2,
        item: show,
        episode: Episode(
          name: 'الحلقة $n',
          url: 'https://animewitcher.test/kuro/$n',
          episode: n,
          serverName: 'الحلقة $n',
        ),
        timestamp: n * 10,
      );
    }

    await tester.pumpWidget(
      _downloadsApp(
        [episode(20, TaskStatus.running), episode(9, TaskStatus.complete)],
        // DownloadsScreen used to force LTR on the whole page; the pager
        // must still be RTL like the other FilterStyleTabBar screens.
        shellDirection: TextDirection.ltr,
      ),
    );
    await tester.pump();

    expect(
      Directionality.of(tester.element(find.byType(TabBarView))),
      TextDirection.rtl,
    );
    expect(find.text('الحلقة 20'), findsOneWidget);
    expect(find.text('الحلقة 9'), findsNothing);

    await tester.fling(find.byType(TabBarView), const Offset(400, 0), 2000);
    await tester.pumpAndSettle();

    expect(find.text('الحلقة 9'), findsOneWidget);
    expect(find.text('مكتمل'), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);
  });

  testWidgets('completed grouped and single cards keep poster on the left', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => '/tmp',
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      ),
    );

    final bleach = MultimediaItem(
      title: 'Bleach',
      url: 'https://animewitcher.test/bleach',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
      tmdbId: 7,
    );
    final kimi = MultimediaItem(
      title: 'Kimi no Koto',
      url: 'https://animewitcher.test/kimi',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
      tmdbId: 8,
    );
    DownloadItem bleachEp(int n) {
      return DownloadItem(
        task: _task(
          taskId: 'bleach-$n',
          filename: 'الحلقة $n.mp4',
          metaData: 'https://animewitcher.test/bleach/$n',
        ),
        status: TaskStatus.complete,
        progress: 1,
        item: bleach,
        episode: Episode(
          name: 'الحلقة $n',
          url: 'https://animewitcher.test/bleach/$n',
          episode: n,
          serverName: 'الحلقة $n',
        ),
        timestamp: n,
      );
    }

    final single = DownloadItem(
      task: _task(
        taskId: 'kimi-9',
        filename: 'الحلقة 9.mp4',
        metaData: 'https://animewitcher.test/kimi/9',
      ),
      status: TaskStatus.complete,
      progress: 1,
      item: kimi,
      episode: Episode(
        name: 'الحلقة 9',
        url: 'https://animewitcher.test/kimi/9',
        episode: 9,
        serverName: 'الحلقة 9',
      ),
      timestamp: 90,
    );

    await tester.pumpWidget(
      _downloadsApp([
        single,
        bleachEp(6),
        bleachEp(5),
      ], shellDirection: TextDirection.ltr),
    );
    await tester.pump();
    await tester.tap(find.text('المكتملة'));
    await tester.pumpAndSettle();

    expect(find.byType(ExpansionTile), findsOneWidget);
    expect(find.text('Kimi no Koto'), findsOneWidget);
    expect(find.text('Bleach'), findsOneWidget);

    final singlePoster = tester.getTopLeft(find.text('Kimi no Koto'));
    final groupPoster = tester.getTopLeft(find.text('Bleach'));
    // Both titles sit to the right of their posters (LTR cards).
    expect(singlePoster.dx, greaterThan(40));
    expect(groupPoster.dx, greaterThan(40));
    expect((singlePoster.dx - groupPoster.dx).abs(), lessThan(24));

    final artifacts = Directory('/opt/cursor/artifacts');
    if (artifacts.existsSync()) {
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('downloads-tab-root')),
        );
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '${artifacts.path}/downloads_completed_cards_ltr.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
  });

  test('active FIFO is oldest first until the user reorders', () {
    final older = _item(
      taskId: 'old-run',
      timestamp: 10,
      filename: 'الحلقة 1.mp4',
      status: TaskStatus.running,
      metaData: 'https://animewitcher.test/black-torch/1',
      episode: Episode(
        name: 'الحلقة 1',
        url: 'https://animewitcher.test/black-torch/1',
        episode: 1,
        serverName: 'الحلقة 1',
      ),
    );
    final newer = _item(
      taskId: 'new-run',
      timestamp: 20,
      filename: 'الحلقة 10.mp4',
      status: TaskStatus.enqueued,
      metaData: 'https://animewitcher.test/black-torch/10',
      episode: Episode(
        name: 'الحلقة 10',
        url: 'https://animewitcher.test/black-torch/10',
        episode: 10,
        serverName: 'الحلقة 10',
      ),
    );
    final collapsed = sortByDownloadQueueOrder(
      collapseDuplicateDownloads([newer, older]).visible,
      idOf: (item) => item.id,
      order: const [],
      fallbackTimestamp: (item) => item.timestamp,
    );
    expect(collapsed.first.id, 'old-run');
    expect(collapsed.last.id, 'new-run');
    expect(
      collapseDuplicateDownloads([newer, older]).visible.map((item) => item.id),
      ['new-run', 'old-run'],
    );
  });

  test(
    'Hive metadata is enough to show a waiting row before enqueue returns',
    () {
      final task = _task(
        taskId: 'ep11',
        filename: 'الحلقة 11 (480p).mp4',
        metaData: 'https://animewitcher.test/black-torch/11',
      );
      final incoming = downloadItemFromTaskMetadata(
        task: task,
        status: TaskStatus.enqueued,
        metadata: {
          'item': _blackTorch().toJson(),
          'episode': Episode(
            name: 'الحلقة 11',
            url: 'https://animewitcher.test/black-torch/11',
            episode: 11,
            serverName: 'الحلقة 11',
          ).toJson(),
          'timestamp': 50,
        },
      );
      expect(incoming, isNotNull);
      expect(incoming!.id, 'ep11');
      expect(incoming.status, TaskStatus.enqueued);
      expect(incoming.episode?.name, 'الحلقة 11');
      expect(isActiveDownloadStatus(incoming.status), isTrue);

      final running = _item(
        taskId: 'ep10',
        timestamp: 40,
        filename: 'الحلقة 10.mp4',
        status: TaskStatus.running,
        metaData: 'https://animewitcher.test/black-torch/10',
        episode: Episode(
          name: 'الحلقة 10',
          url: 'https://animewitcher.test/black-torch/10',
          episode: 10,
          serverName: 'الحلقة 10',
        ),
      );
      final visible = collapseDuplicateDownloads([running, incoming]).visible;
      expect(visible.map((row) => row.id), ['ep10', 'ep11']);
      expect(visible.last.episode?.name, 'الحلقة 11');
    },
  );
}
