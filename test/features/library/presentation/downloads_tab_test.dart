import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/providers/episode_sort_provider.dart';
import 'package:animewitcher/core/services/download_concurrency.dart';
import 'package:animewitcher/core/services/download_v2/download_continued_processing_v2.dart';
import 'package:animewitcher/core/utils/download_progress_data.dart';
import 'package:animewitcher/features/library/presentation/download_progress_v2_provider.dart';
import 'package:animewitcher/core/services/notification_service.dart';
import 'package:animewitcher/core/utils/download_cleanup.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/widgets/downloads_tab.dart';
import 'package:animewitcher/shared/widgets/underline_segment_tabs.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path/path.dart' as p;

import '../../../support/test_fonts.dart';
import '../../../support/debug_shots.dart';
import '../../../support/widget_completion.dart';

class _ArtworkPaths extends PathProviderPlatform {
  _ArtworkPaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

late Directory _artworkFixtureRoot;

Future<void> _prepareArtworkStorage(WidgetTester tester) async {
  final original = PathProviderPlatform.instance;
  PathProviderPlatform.instance = _ArtworkPaths(_artworkFixtureRoot.path);
  addTearDown(() {
    PathProviderPlatform.instance = original;
  });
}

Future<void> _awaitArtworkLookups(WidgetTester tester) async {
  for (final builder in tester.widgetList<FutureBuilder<File?>>(
    find.byWidgetPredicate((widget) => widget is FutureBuilder<File?>),
  )) {
    final future = builder.future;
    if (future != null) {
      await pumpUntilFuture(
        tester,
        future,
        'completed downloads artwork lookup',
      );
    }
  }
  await tester.pump();
}

Future<void> _captureSelectionPreview(WidgetTester tester, String name) async {
  final directory = debugShotDirectory();
  if (directory == null) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('downloads-tab-root')),
    );
    final preview = await boundary.toImage(pixelRatio: 2);
    final data = await preview.toByteData(format: ui.ImageByteFormat.png);
    File('${directory.path}/$name.png')
        .writeAsBytesSync(data!.buffer.asUint8List());
  });
}

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
  String? logicalId,
}) {
  return DownloadItem(
    task: _task(taskId: taskId, filename: filename, metaData: metaData),
    status: status,
    progress: status == TaskStatus.complete ? 1.0 : 0.4,
    item: _blackTorch(),
    episode: episode ?? _episode9(),
    timestamp: timestamp,
    logicalId: logicalId,
  );
}

DownloadItem _itemTen({
  required String taskId,
  required int timestamp,
  required TaskStatus status,
}) => _item(
  taskId: taskId,
  timestamp: timestamp,
  status: status,
  metaData: 'https://animewitcher.test/black-torch/10',
  episode: Episode(
    name: 'الحلقة 10',
    url: 'https://animewitcher.test/black-torch/10',
    episode: 10,
    serverName: 'الحلقة 10',
  ),
);

class _StubDownloadsNotifier extends DownloadsNotifier {
  _StubDownloadsNotifier(
    this._items, {
    this.resumeError,
    this.retryError,
    this.pauseAction,
    this.removeAction,
    this.removeResult = true,
    this.remainingIdsAfterRemove,
  });

  final List<DownloadItem> _items;
  final Object? resumeError;
  final Object? retryError;
  final Future<void> Function()? pauseAction;
  final Future<void> Function()? removeAction;
  final bool removeResult;
  final Set<String>? remainingIdsAfterRemove;
  int pauseCalls = 0;
  int removeCalls = 0;
  final List<String> pausedIds = [];
  final List<String> resumedIds = [];
  final List<String> retriedIds = [];
  final List<List<String>> removedBatches = [];

  @override
  Future<List<DownloadItem>> build() async => _items;

  void publish(List<DownloadItem> items) => state = AsyncData(items);

  @override
  Future<void> pauseDownload(String taskId) async {
    pauseCalls++;
    pausedIds.add(taskId);
    await pauseAction?.call();
  }

  @override
  Future<void> removeDownload(DownloadItem item) async {
    removeCalls++;
    await removeAction?.call();
  }

  @override
  Future<bool> removeDownloads(List<DownloadItem> items) async {
    removeCalls++;
    removedBatches.add(items.map((item) => item.id).toList());
    await removeAction?.call();
    final remainingIds = remainingIdsAfterRemove;
    if (remainingIds != null) {
      state = AsyncData(
        _items.where((item) => remainingIds.contains(item.id)).toList(),
      );
    }
    return removeResult;
  }

  @override
  Future<void> retryDownload(String taskId) async {
    retriedIds.add(taskId);
    final error = retryError;
    if (error != null) throw error;
  }

  @override
  Future<void> resumeDownload(String taskId) async {
    resumedIds.add(taskId);
    final error = resumeError;
    if (error != null) throw error;
  }
}

class _StubEpisodeSortAscendingNotifier extends EpisodeSortAscendingNotifier {
  _StubEpisodeSortAscendingNotifier(this._value);

  final bool _value;

  @override
  bool build() => _value;
}

Widget _downloadsApp(
  List<DownloadItem> items, {
  bool previewTheme = false,
  TextDirection? shellDirection,
  bool episodeSortAscending = true,
  Object? resumeError,
  Object? retryError,
  NotificationService? notificationService,
  _StubDownloadsNotifier? notifier,
  Map<String, DownloadProgressData>? progressData,
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
      downloadsProvider.overrideWith(
        () =>
            notifier ??
            _StubDownloadsNotifier(
              items,
              resumeError: resumeError,
              retryError: retryError,
            ),
      ),
      if (progressData != null)
        downloadProgressProvider.overrideWith((ref) => progressData),
      if (notificationService != null)
        notificationServiceProvider.overrideWithValue(notificationService),
      episodeSortAscendingProvider.overrideWith(
        () => _StubEpisodeSortAscendingNotifier(episodeSortAscending),
      ),
    ],
    child: MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: previewTheme
          ? ThemeData(
              useMaterial3: true,
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF52C6F5),
                brightness: Brightness.dark,
              ),
              scaffoldBackgroundColor: const Color(0xFF0B1422),
            )
          : null,
      home: home,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (debugShotDirectory() != null) {
      await TestFonts.loadFamily('Roboto', [
        '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
        '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
      ]);
      await TestFonts.loadFamily('MaterialIcons', [
        TestFonts.materialFont('MaterialIcons-Regular.otf'),
      ]);
    }
    _artworkFixtureRoot = await Directory.systemTemp.createTemp(
      'aw-downloads-tab-artwork-',
    );
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _ArtworkPaths(_artworkFixtureRoot.path);
    try {
      // Initialize the singleton before any widget fake zone can own its I/O.
      await DefaultCacheManager()
          .getFileFromCache('downloads-tab-artwork-fixture')
          .timeout(const Duration(seconds: 5));
    } finally {
      PathProviderPlatform.instance = original;
    }
  });
  tearDownAll(() => _artworkFixtureRoot.delete(recursive: true));

  testWidgets('global pause controls all active rows in queue order', (
    tester,
  ) async {
    final notifier = _StubDownloadsNotifier([
      _item(taskId: 'first', timestamp: 1, status: TaskStatus.running),
      _itemTen(taskId: 'second', timestamp: 2, status: TaskStatus.enqueued),
    ]);
    await tester.pumpWidget(_downloadsApp([], notifier: notifier));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('downloads-pause-resume-all')));
    await tester.pumpAndSettle();
    expect(notifier.pausedIds, ['first', 'second']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('global resume is shown when every active download is paused', (
    tester,
  ) async {
    final notifier = _StubDownloadsNotifier([
      _item(taskId: 'a', timestamp: 1, status: TaskStatus.paused),
      _itemTen(taskId: 'b', timestamp: 2, status: TaskStatus.paused),
    ]);
    await tester.pumpWidget(_downloadsApp([], notifier: notifier));
    await tester.pumpAndSettle();

    expect(find.text('إكمال الكل'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('downloads-pause-resume-all')));
    await tester.pumpAndSettle();
    expect(notifier.resumedIds, ['a', 'b']);
  });

  testWidgets('global resume ignores failed rows when paused rows remain', (
    tester,
  ) async {
    final notifier = _StubDownloadsNotifier([
      _item(taskId: 'paused', timestamp: 1, status: TaskStatus.paused),
      _itemTen(taskId: 'failed', timestamp: 2, status: TaskStatus.failed),
    ]);
    await tester.pumpWidget(_downloadsApp([], notifier: notifier));
    await tester.pumpAndSettle();

    expect(find.text('إكمال الكل'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('downloads-pause-resume-all')));
    await tester.pumpAndSettle();

    expect(notifier.resumedIds, ['paused']);
    expect(notifier.retriedIds, isEmpty);
  });

  testWidgets(
    'long press selects active rows and bulk delete targets only those rows',
    (tester) async {
      final notifier = _StubDownloadsNotifier([
        _item(taskId: 'a', timestamp: 1, status: TaskStatus.running),
        _itemTen(taskId: 'b', timestamp: 2, status: TaskStatus.running),
      ]);
      await tester.pumpWidget(_downloadsApp([], notifier: notifier));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('الحلقة 9').first);
      await tester.pumpAndSettle();
      expect(find.text('1 محدد'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byIcon(Icons.check_circle_rounded), findsWidgets);
      await tester.tap(find.widgetWithText(FilledButton, 'حذف'));
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(DownloadsTab)),
      )!;
      await tester.tap(find.widgetWithText(FilledButton, l10n.delete).last);
      await tester.pumpAndSettle();
      expect(notifier.removedBatches, [
        <String>['a'],
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('partial bulk delete drops selection for rows already deleted', (
    tester,
  ) async {
    final first = _item(
      taskId: 'deleted',
      timestamp: 1,
      status: TaskStatus.running,
    );
    final second = _itemTen(
      taskId: 'failed-delete',
      timestamp: 2,
      status: TaskStatus.running,
    );
    final notifier = _StubDownloadsNotifier(
      [first, second],
      removeResult: false,
      remainingIdsAfterRemove: {'failed-delete'},
    );
    await tester.pumpWidget(_downloadsApp([], notifier: notifier));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('الحلقة 9').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('الحلقة 10'));
    await tester.pumpAndSettle();
    expect(find.text('2 محدد'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'حذف'));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(DownloadsTab)),
    )!;
    await tester.tap(find.widgetWithText(FilledButton, l10n.delete).last);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('deleted')), findsNothing);
    expect(find.byKey(const ValueKey('failed-delete')), findsOneWidget);
    expect(find.text('1 محدد'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('failed-delete')),
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('failed-delete')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('downloads-selection-bar')), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('selection bar can select every row in the active tab', (
    tester,
  ) async {
    final notifier = _StubDownloadsNotifier([
      _item(taskId: 'a', timestamp: 1, status: TaskStatus.running),
      _itemTen(taskId: 'b', timestamp: 2, status: TaskStatus.paused),
      _item(taskId: 'done', timestamp: 3, status: TaskStatus.complete),
    ]);
    await tester.pumpWidget(_downloadsApp([], notifier: notifier));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('الحلقة 9').first);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('downloads-selection-bar')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('downloads-select-all')));
    await tester.pumpAndSettle();

    expect(find.text('2 محدد'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    for (final id in ['a', 'b']) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey(id)),
          matching: find.byIcon(Icons.check_circle_rounded),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets(
    'active selection keeps card and poster aligned and tints the card',
    (tester) async {
      final notifier = _StubDownloadsNotifier([
        _item(taskId: 'a', timestamp: 1, status: TaskStatus.running),
        _itemTen(taskId: 'b', timestamp: 2, status: TaskStatus.paused),
      ]);
      await tester.pumpWidget(
        _downloadsApp([], notifier: notifier, previewTheme: true),
      );
      await tester.pumpAndSettle();

      final first = find.byKey(const ValueKey('a'));
      final poster = find
          .descendant(of: first, matching: find.byType(CachedNetworkImage))
          .first;
      final cardBefore = tester.getRect(first);
      final posterBefore = tester.getRect(poster);
      final deleteAll = tester.widget<FilledButton>(
        find.byKey(const ValueKey('downloads-delete-all')),
      );
      expect(
        deleteAll.style!.backgroundColor!.resolve({}),
        Colors.red.shade700,
      );
      expect(
        deleteAll.style!.backgroundColor!.resolve({WidgetState.disabled}),
        Colors.red.shade700,
      );

      await tester.longPress(first);
      await tester.pumpAndSettle();
      expect(tester.getRect(first).left, cardBefore.left);
      expect(tester.getRect(first).width, cardBefore.width);
      expect(tester.getRect(poster).left, posterBefore.left);
      expect(find.byType(Checkbox), findsNothing);
      expect(
        find.descendant(
          of: first,
          matching: find.byIcon(Icons.check_circle_rounded),
        ),
        findsOneWidget,
      );
      final card = tester.widget<Card>(
        find.descendant(of: first, matching: find.byType(Card)),
      );
      final border = (card.shape! as RoundedRectangleBorder).side;
      final primary = Theme.of(tester.element(first)).colorScheme.primary;
      expect(border.color, primary);
      expect(border.width, 2);
      expect(card.color, primary.withValues(alpha: 0.24));
      final deleteSelected = tester.widget<FilledButton>(
        find.descendant(
          of: find.byKey(const ValueKey('downloads-selection-bar')),
          matching: find.widgetWithText(FilledButton, 'حذف'),
        ),
      );
      expect(
        deleteSelected.style!.backgroundColor!.resolve({}),
        Colors.red.shade700,
      );
      expect(
        deleteSelected.style!.backgroundColor!.resolve({WidgetState.disabled}),
        Colors.red.shade700,
      );
    },
  );

  testWidgets('completed episode selection keeps its width and highlights it', (
    tester,
  ) async {
    await _prepareArtworkStorage(tester);
    final notifier = _StubDownloadsNotifier([
      _item(taskId: 'ep9', timestamp: 1, status: TaskStatus.complete),
      _itemTen(taskId: 'ep10', timestamp: 2, status: TaskStatus.complete),
    ]);
    await tester.pumpWidget(
      _downloadsApp([], notifier: notifier, previewTheme: true),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(DownloadsTab)),
    )!;
    await tester.tap(find.text(l10n.downloadsTabCompleted));
    await tester.pumpAndSettle();
    await _awaitArtworkLookups(tester);
    await tester.tap(find.text('Black Torch'));
    await tester.pumpAndSettle();

    final episode = find.byKey(const ValueKey('ep9'));
    final episodeBefore = tester.getRect(episode);
    await tester.longPress(find.text('الحلقة 9'));
    await tester.pumpAndSettle();
    expect(tester.getRect(episode).left, episodeBefore.left);
    expect(tester.getRect(episode).width, episodeBefore.width);
    expect(find.byType(Checkbox), findsNothing);
    expect(
      find.descendant(
        of: episode,
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsOneWidget,
    );
    final decoration =
        tester
                .widget<AnimatedContainer>(
                  find
                      .descendant(
                        of: episode,
                        matching: find.byType(AnimatedContainer),
                      )
                      .first,
                )
                .decoration!
            as BoxDecoration;
    final primary = Theme.of(tester.element(episode)).colorScheme.primary;
    expect(decoration.color, primary.withValues(alpha: 0.24));
    expect(decoration.border!.top.color, primary);
  });

  testWidgets('selection ends when the selected row leaves the current tab', (
    tester,
  ) async {
    final notifier = _StubDownloadsNotifier([
      _item(taskId: 'moving', timestamp: 1, status: TaskStatus.running),
      _itemTen(taskId: 'remaining', timestamp: 2, status: TaskStatus.running),
    ]);
    await tester.pumpWidget(_downloadsApp([], notifier: notifier));
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const ValueKey('moving')));
    await tester.pumpAndSettle();
    expect(find.text('1 محدد'), findsOneWidget);

    notifier.publish([
      _item(taskId: 'moving', timestamp: 1, status: TaskStatus.complete),
      _itemTen(taskId: 'remaining', timestamp: 2, status: TaskStatus.running),
    ]);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('downloads-selection-bar')), findsNothing);
    expect(find.byKey(const ValueKey('remaining')), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byKey(const ValueKey('downloads-delete-all')), findsOneWidget);
  });

  testWidgets('mixed selection pauses running and resumes paused only', (
    tester,
  ) async {
    final notifier = _StubDownloadsNotifier([
      _item(taskId: 'running', timestamp: 1, status: TaskStatus.running),
      _itemTen(taskId: 'paused', timestamp: 2, status: TaskStatus.paused),
      _item(
        taskId: 'failed',
        timestamp: 3,
        status: TaskStatus.failed,
        metaData: 'https://animewitcher.test/black-torch/11',
        episode: Episode(
          name: 'الحلقة 11',
          url: 'https://animewitcher.test/black-torch/11',
          episode: 11,
          serverName: 'الحلقة 11',
        ),
      ),
    ]);
    await tester.pumpWidget(_downloadsApp([], notifier: notifier));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('الحلقة 9').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('الحلقة 10'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('الحلقة 11'));
    await tester.pumpAndSettle();
    expect(find.text('3 محدد'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'إكمال'));
    await tester.pumpAndSettle();
    expect(notifier.resumedIds, ['paused']);
    expect(notifier.retriedIds, isEmpty);

    await tester.tap(find.widgetWithText(FilledButton, 'إيقاف'));
    await tester.pumpAndSettle();
    expect(notifier.pausedIds, ['running']);
  });

  testWidgets('completed group allows selecting one episode only', (
    tester,
  ) async {
    await _prepareArtworkStorage(tester);
    final notifier = _StubDownloadsNotifier([
      _item(taskId: 'ep9', timestamp: 1, status: TaskStatus.complete),
      _itemTen(taskId: 'ep10', timestamp: 2, status: TaskStatus.complete),
    ]);
    await tester.pumpWidget(_downloadsApp([], notifier: notifier));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(DownloadsTab)),
    )!;
    await tester.tap(find.text(l10n.downloadsTabCompleted));
    await tester.pumpAndSettle();
    await _awaitArtworkLookups(tester);
    await tester.tap(find.text('Black Torch'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('الحلقة 9'));
    await tester.pumpAndSettle();
    expect(find.text('1 محدد'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'حذف'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, l10n.delete).last);
    await tester.pumpAndSettle();
    expect(notifier.removedBatches, [
      <String>['ep9'],
    ]);
  });

  testWidgets('completed selection bar is bottom aligned and delete only', (
    tester,
  ) async {
    await _prepareArtworkStorage(tester);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final notifier = _StubDownloadsNotifier([
      _item(taskId: 'a', timestamp: 1, status: TaskStatus.complete),
      _itemTen(taskId: 'b', timestamp: 2, status: TaskStatus.complete),
    ]);
    await tester.pumpWidget(
      _downloadsApp([], notifier: notifier, previewTheme: true),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(DownloadsTab)),
    )!;
    await tester.tap(find.text(l10n.downloadsTabCompleted));
    await tester.pumpAndSettle();
    await _awaitArtworkLookups(tester);

    await tester.longPress(find.text('Black Torch'));
    await tester.pumpAndSettle();
    final bar = find.byKey(const ValueKey('downloads-selection-bar'));
    expect(bar, findsOneWidget);
    expect(tester.getBottomRight(bar).dy, greaterThan(760));
    expect(
      find.descendant(of: bar, matching: find.byIcon(Icons.pause_rounded)),
      findsNothing,
    );
    expect(
      find.descendant(of: bar, matching: find.byIcon(Icons.play_arrow_rounded)),
      findsNothing,
    );
    expect(
      find.descendant(
        of: bar,
        matching: find.byKey(const ValueKey('downloads-select-all')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: bar,
        matching: find.byIcon(Icons.delete_outline_rounded),
      ),
      findsOneWidget,
    );
    final deleteButton = find.descendant(
      of: bar,
      matching: find.widgetWithText(FilledButton, l10n.delete),
    );
    final selectAll = find.byKey(const ValueKey('downloads-select-all'));
    expect(tester.getSize(deleteButton).width, greaterThan(200));
    final completedDelete = tester.widget<FilledButton>(deleteButton);
    expect(
      completedDelete.style!.backgroundColor!.resolve({}),
      Colors.red.shade700,
    );
    expect(
      tester.getCenter(selectAll).dx,
      lessThan(tester.getCenter(deleteButton).dx),
    );
    await _captureSelectionPreview(tester, 'completed_selection_new');
  });

  testWidgets('wrapped selection bar never covers the final active row', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    DownloadItem activeItem(
      String id,
      int episodeNumber, {
      TaskStatus status = TaskStatus.running,
    }) => _item(
      taskId: id,
      timestamp: episodeNumber,
      status: status,
      metaData: 'https://animewitcher.test/black-torch/$episodeNumber',
      episode: Episode(
        name: 'الحلقة $episodeNumber',
        url: 'https://animewitcher.test/black-torch/$episodeNumber',
        episode: episodeNumber,
        serverName: 'الحلقة $episodeNumber',
      ),
    );
    final notifier = _StubDownloadsNotifier([
      activeItem('first', 1),
      activeItem('paused', 2, status: TaskStatus.paused),
      activeItem('three', 3),
      activeItem('four', 4),
      activeItem('five', 5),
      activeItem('last', 6),
    ]);
    await tester.pumpWidget(
      _downloadsApp([], notifier: notifier, previewTheme: true),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const ValueKey('first')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('downloads-select-all')));
    await tester.pumpAndSettle();

    final bar = find.byKey(const ValueKey('downloads-selection-bar'));
    expect(bar, findsOneWidget);
    expect(
      find.descendant(of: bar, matching: find.byIcon(Icons.pause_rounded)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bar, matching: find.byIcon(Icons.play_arrow_rounded)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: bar,
        matching: find.byIcon(Icons.delete_outline_rounded),
      ),
      findsOneWidget,
    );
    final delete = tester.getRect(
      find.descendant(
        of: bar,
        matching: find.widgetWithText(FilledButton, 'حذف'),
      ),
    );
    final pause = tester.getRect(
      find.descendant(
        of: bar,
        matching: find.widgetWithText(FilledButton, 'إيقاف'),
      ),
    );
    final resume = tester.getRect(
      find.descendant(
        of: bar,
        matching: find.widgetWithText(FilledButton, 'إكمال'),
      ),
    );
    final selectAll = tester.getRect(
      find.byKey(const ValueKey('downloads-select-all')),
    );
    expect(delete.center.dy, closeTo(pause.center.dy, 1));
    expect(pause.center.dy, closeTo(resume.center.dy, 1));
    expect(delete.width, closeTo(pause.width, 1));
    expect(pause.width, closeTo(resume.width, 1));
    expect(selectAll.right, lessThan(resume.left));
    await _captureSelectionPreview(tester, 'active_selection_new');

    await tester.drag(find.byType(ListView).first, const Offset(0, -2000));
    await tester.pumpAndSettle();

    final last = find.byKey(const ValueKey('last'));
    expect(last, findsOneWidget);
    expect(
      tester.getBottomRight(last).dy,
      lessThanOrEqualTo(tester.getTopLeft(bar).dy),
    );
  });

  testWidgets('delete all only targets the active tab', (tester) async {
    final notifier = _StubDownloadsNotifier([
      _item(taskId: 'a', timestamp: 1, status: TaskStatus.running),
      _itemTen(taskId: 'b', timestamp: 2, status: TaskStatus.complete),
    ]);
    await tester.pumpWidget(_downloadsApp([], notifier: notifier));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('downloads-delete-all')));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(DownloadsTab)),
    )!;
    await tester.tap(find.widgetWithText(FilledButton, l10n.delete));
    await tester.pumpAndSettle();
    expect(notifier.removedBatches.single, ['a']);
  });

  testWidgets('completed tab has no delete all and selection deletes items', (
    tester,
  ) async {
    await _prepareArtworkStorage(tester);
    final notifier = _StubDownloadsNotifier([
      _item(taskId: 'a', timestamp: 1, status: TaskStatus.running),
      _itemTen(taskId: 'b', timestamp: 2, status: TaskStatus.complete),
    ]);
    await tester.pumpWidget(_downloadsApp([], notifier: notifier));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(DownloadsTab)),
    )!;

    await tester.tap(find.text(l10n.downloadsTabCompleted));
    await tester.pumpAndSettle();
    await _awaitArtworkLookups(tester);
    expect(find.byKey(const ValueKey('downloads-delete-all')), findsNothing);
    await tester.longPress(find.text('Black Torch'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('downloads-selection-bar')),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, l10n.delete));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, l10n.delete).last);
    await tester.pumpAndSettle();
    expect(notifier.removedBatches.single, ['b']);
  });

  testWidgets('pause failure is shown and the button is usable again', (
    tester,
  ) async {
    final notifications = NotificationService();
    addTearDown(notifications.dispose);
    final notifier = _StubDownloadsNotifier(
      [_item(taskId: 'running-v2', timestamp: 1, status: TaskStatus.running)],
      pauseAction: () async =>
          throw StateError('pause acknowledgement timed out'),
    );
    await tester.pumpWidget(
      _downloadsApp([], notifier: notifier, notificationService: notifications),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithIcon(IconButton, Icons.pause_rounded));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      notifications.toasts.single.message,
      'pause acknowledgement timed out',
    );
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.pause_rounded),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.widgetWithIcon(IconButton, Icons.pause_rounded));
    await tester.pump();
    expect(notifier.pauseCalls, 2);
    notifications.clearToasts();
  });

  testWidgets('pending pause blocks duplicate taps but still allows deletion', (
    tester,
  ) async {
    final pause = Completer<void>();
    final deletion = Completer<void>();
    final notifier = _StubDownloadsNotifier(
      [_item(taskId: 'running-v2', timestamp: 1, status: TaskStatus.running)],
      pauseAction: () => pause.future,
      removeAction: () => deletion.future,
    );
    await tester.pumpWidget(_downloadsApp([], notifier: notifier));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.pause_rounded));
    await tester.pump();
    expect(notifier.pauseCalls, 1);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.pause_rounded),
          )
          .onPressed,
      isNull,
    );
    final deleteButton = find.widgetWithIcon(
      IconButton,
      Icons.delete_outline_rounded,
    );
    expect(tester.widget<IconButton>(deleteButton).onPressed, isNotNull);

    await tester.tap(deleteButton);
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(DownloadsTab)),
    )!;
    await tester.tap(find.widgetWithText(FilledButton, l10n.delete));
    await tester.pumpAndSettle();
    expect(notifier.removeCalls, 1);
    expect(tester.widget<IconButton>(deleteButton).onPressed, isNull);

    pause.complete();
    deletion.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(deleteButton).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  for (final completed in [false, true]) {
    testWidgets(
      '${completed ? 'completed group' : 'active row'} deletion failure is shown and can be retried',
      (tester) async {
        final notifications = NotificationService();
        addTearDown(notifications.dispose);
        if (completed) await _prepareArtworkStorage(tester);
        final notifier = _StubDownloadsNotifier(
          [
            _item(
              taskId: 'delete-v2',
              timestamp: 1,
              status: completed ? TaskStatus.complete : TaskStatus.running,
            ),
          ],
          removeAction: () async =>
              throw StateError('download still has a native writer'),
        );
        await tester.pumpWidget(
          _downloadsApp(
            [],
            notifier: notifier,
            notificationService: notifications,
          ),
        );
        await tester.pumpAndSettle();
        final l10n = AppLocalizations.of(
          tester.element(find.byType(DownloadsTab)),
        )!;
        if (completed) {
          await tester.tap(find.text(l10n.downloadsTabCompleted));
          await tester.pumpAndSettle();
          await _awaitArtworkLookups(tester);
        }
        for (var attempt = 0; attempt < 2; attempt++) {
          await tester.tap(
            find.widgetWithIcon(IconButton, Icons.delete_outline_rounded),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.widgetWithText(
              FilledButton,
              completed ? l10n.deleteAll : l10n.delete,
            ),
          );
          // Keep the one-second error toast visible while the dialog closes.
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(
            notifications.toasts.single.message,
            'download still has a native writer',
          );
          notifications.clearToasts();
          await tester.pumpAndSettle();
        }
        expect(notifier.removeCalls, 2);
      },
    );
  }

  testWidgets('resume failure is caught and surfaced as an error toast', (
    tester,
  ) async {
    final notifications = NotificationService();
    addTearDown(() {
      notifications.clearToasts();
      notifications.dispose();
    });

    await tester.pumpWidget(
      _downloadsApp(
        <DownloadItem>[
          _item(taskId: 'paused-v2', timestamp: 1, status: TaskStatus.paused),
        ],
        resumeError: StateError('source re-selection required'),
        notificationService: notifications,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithIcon(IconButton, Icons.play_arrow_rounded));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(notifications.toasts, hasLength(1));
    expect(notifications.toasts.single.type, ToastType.error);
    expect(
      notifications.toasts.single.message,
      contains('source re-selection required'),
    );

    notifications.clearToasts();
    await tester.pump();
  });

  testWidgets('failed downloads offer retry instead of paused resume', (
    tester,
  ) async {
    final notifications = NotificationService();
    addTearDown(() {
      notifications.clearToasts();
      notifications.dispose();
    });
    await tester.pumpWidget(
      _downloadsApp(
        <DownloadItem>[
          _item(taskId: 'failed-v2', timestamp: 1, status: TaskStatus.failed),
        ],
        resumeError: StateError('incorrect paused-resume command'),
        retryError: StateError('retry could not resolve source'),
        notificationService: notifications,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('فشل التنزيل'), findsOneWidget);
    expect(find.text('متوقف مؤقتاً'), findsNothing);
    expect(
      find.widgetWithIcon(IconButton, Icons.play_arrow_rounded),
      findsNothing,
    );
    await tester.tap(find.byTooltip('إعادة المحاولة'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      notifications.toasts.single.message,
      contains('retry could not resolve source'),
    );
    notifications.clearToasts();
    await tester.pump();
  });

  testWidgets('delete preserves label lookalikes', (tester) async {
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

      await deleteDownloadedVideo(
        taskFile,

        appDownloadRoots: [p.join(root.path, 'AnimeWitcher', 'Downloads')],
      );

      expect(await taskFile.exists(), isFalse);
      expect(await reconstructed.exists(), isTrue);
      expect(await series.exists(), isTrue);
    });
  });

  testWidgets(
    'deleting the last episode preserves unknown series-folder evidence',
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
        await File(p.join(season.path, '${p.basename(video.path)}.part'))
            .writeAsBytes([1]);
        await File(p.join(season.path, '${p.basename(video.path)}.tmp'))
            .writeAsBytes([1]);
        await File(p.join(season.path, '${p.basename(video.path)}.download'))
            .writeAsBytes([1]);
        await File(p.join(season.path, 'thumb.jpg')).writeAsBytes([1]);
        await Directory(p.join(series.path, 'Season 2')).create();

        final otherSeries = Directory(p.join(downloadsRoot.path, 'Bleach'));
        await otherSeries.create();
        final otherVideo = File(p.join(otherSeries.path, 'الحلقة 1.mp4'));
        await otherVideo.writeAsBytes(List<int>.filled(32, 3));

        await deleteDownloadedVideo(
          video,

          appDownloadRoots: [p.join(root.path, 'AnimeWitcher', 'Downloads')],
        );

        expect(await video.exists(), isFalse);
        expect(await File('${video.path}.part').exists(), isFalse);
        expect(await File('${video.path}.tmp').exists(), isFalse);
        expect(await File('${video.path}.download').exists(), isFalse);
        // DM-14: recursive cleanup may not infer ownership of unrelated files
        // or empty user directories merely because the selected video is gone.
        expect(await series.exists(), isTrue);
        expect(await File(p.join(season.path, 'thumb.jpg')).exists(), isTrue);
        expect(
          await Directory(p.join(series.path, 'Season 2')).exists(),
          isTrue,
        );
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

      await deleteDownloadedVideo(
        video,

        appDownloadRoots: [p.join(root.path, 'AnimeWitcher', 'Downloads')],
      );

      expect(await video.exists(), isFalse);
      expect(await part.exists(), isFalse);
      expect(await tmp.exists(), isFalse);
      expect(await download.exists(), isFalse);
      expect(await other.exists(), isTrue);
      expect(await series.exists(), isTrue);
    });
  });

  testWidgets(
    'two complete records for the same episode collapse into one grouped episode',
    (tester) async {
      await _prepareArtworkStorage(tester);
      final older = _item(taskId: 'old-complete', timestamp: 100);
      final newer = _item(taskId: 'new-complete', timestamp: 200);
      expect(older.task.taskId, isNot(newer.task.taskId));
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
        collapseDuplicateDownloads([older, newer])
            .extraCompleteRecords
            .single
            .id,
        'old-complete',
      );

      await tester.pumpWidget(_downloadsApp([older, newer]));
      await tester.pump();

      expect(find.text('المكتملة'), findsOneWidget);
      await tester.tap(find.text('المكتملة'));
      await tester.pumpAndSettle();

      expect(find.text('Black Torch'), findsOneWidget);
      expect(find.byType(ExpansionTile), findsOneWidget);
      expect(find.text('حلقة'), findsOneWidget);
      expect(find.text('مكتمل'), findsNothing);
      expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
      expect(find.text('الحلقة 9'), findsNothing);

      await tester.tap(find.text('Black Torch'));
      await tester.pumpAndSettle();
      await _awaitArtworkLookups(tester);

      expect(find.text('الحلقة 9'), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_fill_rounded), findsNothing);
      expect(
        find.descendant(
          of: find.byType(ExpansionTile),
          matching: find.byIcon(Icons.delete_outline_rounded),
        ),
        findsNWidgets(2),
      );
      expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);
    },
  );

  test('canonical identity is task metaData / episode.url, not taskId', () {
    final a = _item(taskId: 'task-a', timestamp: 1);
    final b = _item(taskId: 'task-b', timestamp: 2);
    expect(a.task.metaData, a.episode!.url);
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
              status: TaskStatus.running,
              totalSize: 365400000,
            ),
            waiting.task.metaData: DownloadProgressData(
              taskId: 'ep4',
              progress: 0,
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
    expect(
      find.widgetWithIcon(IconButton, Icons.pause_rounded),
      findsNWidgets(2),
    );
    expect(
      find.widgetWithIcon(IconButton, Icons.play_arrow_rounded),
      findsNothing,
    );
    expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(find.byType(ReorderableListView), findsNothing);

    final artifacts = debugShotDirectory();
    if (artifacts == null) return;

    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('downloads-waiting-row')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${artifacts.path}/downloads_waiting_in_app.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());
      File('${artifacts.path}/downloads_no_reorder_handle.png')
          .writeAsBytesSync(bytes.buffer.asUint8List());
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
    expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);
    expect(find.byType(FilterStyleTabBar), findsOneWidget);

    final artifacts = debugShotDirectory();
    if (artifacts != null) {
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('downloads-tab-root')),
        );
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${artifacts.path}/downloads_active_ungrouped.png')
            .writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
  });

  testWidgets('completed tab groups two episodes and uses dual count', (
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
    expect(find.text('حلقتان'), findsOneWidget);
    expect(find.text('مكتمل'), findsNothing);
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
    expect(
      Directionality.of(tester.element(find.byType(TabBarView))),
      TextDirection.rtl,
    );
    expect(
      Directionality.of(tester.element(find.byType(ExpansionTile))),
      TextDirection.ltr,
    );

    final artifacts = debugShotDirectory();
    if (artifacts != null) {
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('downloads-tab-root')),
        );
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${artifacts.path}/downloads_completed_grouped.png')
            .writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
  });

  testWidgets('completed episodes follow the details-page sort direction', (
    tester,
  ) async {
    await _prepareArtworkStorage(tester);
    final show = MultimediaItem(
      title: 'Scrambled',
      url: 'https://animewitcher.test/scrambled',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
      tmdbId: 99,
    );

    DownloadItem episode(int number, int timestamp) => DownloadItem(
      task: _task(
        taskId: 'scrambled-$number',
        filename: 'الحلقة $number.mp4',
        metaData: 'https://animewitcher.test/scrambled/$number',
      ),
      status: TaskStatus.complete,
      progress: 1,
      item: show,
      episode: Episode(
        name: 'الحلقة $number',
        url: 'https://animewitcher.test/scrambled/$number',
        season: 1,
        episode: number,
        serverName: 'الحلقة $number',
      ),
      timestamp: timestamp,
    );

    await tester.pumpWidget(
      _downloadsApp([
        episode(10, 300),
        episode(12, 200),
        episode(11, 100),
      ], episodeSortAscending: false),
    );
    await tester.pump();
    await tester.tap(find.text('المكتملة'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scrambled'));
    await tester.pumpAndSettle();
    await _awaitArtworkLookups(tester);

    final episode12Y = tester.getTopLeft(find.text('الحلقة 12')).dy;
    final episode11Y = tester.getTopLeft(find.text('الحلقة 11')).dy;
    final episode10Y = tester.getTopLeft(find.text('الحلقة 10')).dy;
    expect(episode12Y, lessThan(episode11Y));
    expect(episode11Y, lessThan(episode10Y));
  });

  testWidgets('tab swipe follows RTL and lands on the completed anime group', (
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
        episode(9, TaskStatus.complete),
      ], shellDirection: TextDirection.ltr),
    );
    await tester.pump();

    expect(
      Directionality.of(tester.element(find.byType(TabBarView))),
      TextDirection.rtl,
    );
    expect(find.text('الحلقة 20'), findsOneWidget);

    await tester.fling(find.byType(TabBarView), const Offset(400, 0), 2000);
    await tester.pumpAndSettle();

    expect(find.text('Kuroneko'), findsOneWidget);
    expect(find.byType(ExpansionTile), findsOneWidget);
    expect(find.text('حلقة'), findsOneWidget);
    expect(find.text('الحلقة 9'), findsNothing);
    expect(find.text('مكتمل'), findsNothing);
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
    expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);

    await tester.tap(find.text('Kuroneko'));
    await tester.pumpAndSettle();
    expect(find.text('الحلقة 9'), findsOneWidget);
  });

  testWidgets('completed single and multi downloads are both anime groups', (
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
        bleachEp(4),
      ], shellDirection: TextDirection.ltr),
    );
    await tester.pump();
    await tester.tap(find.text('المكتملة'));
    await tester.pumpAndSettle();

    expect(find.byType(ExpansionTile), findsNWidgets(2));
    expect(find.text('Kimi no Koto'), findsOneWidget);
    expect(find.text('Bleach'), findsOneWidget);
    expect(find.text('حلقة'), findsOneWidget);
    expect(find.text('3 حلقات'), findsOneWidget);
    final countParagraph = tester.renderObject<RenderParagraph>(
      find.text('3 حلقات'),
    );
    final numberBox = countParagraph
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 1),
        )
        .single;
    final nounBoxes = countParagraph.getBoxesForSelection(
      const TextSelection(baseOffset: 2, extentOffset: 7),
    );
    // In Arabic reading order the number comes first, at the right.
    expect(
      numberBox.left,
      greaterThan(
        nounBoxes.map((box) => box.right).reduce((a, b) => a > b ? a : b),
      ),
    );
    expect(countParagraph.textDirection, TextDirection.rtl);
    expect(countParagraph.textAlign, TextAlign.left);
    ({Rect card, Rect poster, Rect title, Rect phrase, double glyphLeft})
    completedGeometry() {
      final group = find.ancestor(
        of: find.text('Bleach'),
        matching: find.byType(ExpansionTile),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text('3 حلقات'),
      );
      final boxes = paragraph.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 7),
      );
      final glyphLeft = boxes
          .map((box) => box.left)
          .reduce((a, b) => a < b ? a : b);
      return (
        card: tester.getRect(group),
        poster: tester.getRect(
          find.descendant(of: group, matching: find.byType(ClipRRect)).first,
        ),
        title: tester.getRect(find.text('Bleach')),
        phrase: tester.getRect(find.text('3 حلقات')),
        glyphLeft: paragraph.localToGlobal(Offset(glyphLeft, 0)).dx,
      );
    }

    final leftLayout = completedGeometry();
    expect(leftLayout.poster.left, lessThan(leftLayout.title.left));
    expect(leftLayout.title.left, closeTo(leftLayout.poster.right + 16, 0.5));
    // The whole phrase sits at the left after the 14px icon and 4px gap.
    expect(leftLayout.glyphLeft, closeTo(leftLayout.title.left + 18, 0.5));
    expect(leftLayout.glyphLeft, closeTo(leftLayout.phrase.left, 0.5));

    await tester.pumpWidget(
      _downloadsApp([
        single,
        bleachEp(6),
        bleachEp(5),
        bleachEp(4),
      ], shellDirection: TextDirection.rtl),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('المكتملة'));
    await tester.pumpAndSettle();
    final arabicLayout = completedGeometry();
    expect(arabicLayout.card, leftLayout.card);
    expect(arabicLayout.poster, leftLayout.poster);
    expect(arabicLayout.title, leftLayout.title);
    expect(arabicLayout.phrase, leftLayout.phrase);
    expect(arabicLayout.glyphLeft, closeTo(leftLayout.glyphLeft, 0.5));
    expect(find.text('مكتمل'), findsNothing);
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing);

    final singlePoster = tester.getTopLeft(find.text('Kimi no Koto'));
    final groupPoster = tester.getTopLeft(find.text('Bleach'));
    expect(singlePoster.dx, greaterThan(40));
    expect(groupPoster.dx, greaterThan(40));
    expect((singlePoster.dx - groupPoster.dx).abs(), lessThan(24));

    await tester.tap(find.text('Kimi no Koto'));
    await tester.pumpAndSettle();
    expect(find.text('الحلقة 9'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_fill_rounded), findsNothing);
    expect(
      find.descendant(
        of: find.byType(ExpansionTile),
        matching: find.byIcon(Icons.delete_outline_rounded),
      ),
      findsNWidgets(3),
    );

    final artifacts = debugShotDirectory();
    if (artifacts != null) {
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('downloads-tab-root')),
        );
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${artifacts.path}/downloads_completed_cards_ltr.png')
            .writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
  });

  test('active FIFO is oldest first', () {
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

  testWidgets('paused downloads stay paused, not fake-running', (tester) async {
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

    DownloadItem paused(int n) => DownloadItem(
      task: _task(
        taskId: 'ep$n',
        filename: 'الحلقة $n.mp4',
        metaData: 'https://animewitcher.test/black-torch/$n',
      ),
      status: TaskStatus.paused,
      progress: 0.02,
      item: _blackTorch(),
      episode: Episode(
        name: 'الحلقة $n',
        url: 'https://animewitcher.test/black-torch/$n',
        episode: n,
        serverName: 'الحلقة $n',
      ),
      timestamp: n * 10,
    );

    await tester.pumpWidget(_downloadsApp([paused(6), paused(7), paused(8)]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('متوقف مؤقتاً'), findsNWidgets(3));
    expect(find.text('جارٍ التنزيل...'), findsNothing);
    expect(
      find.widgetWithIcon(IconButton, Icons.play_arrow_rounded),
      findsNWidgets(3),
    );
    expect(find.widgetWithIcon(IconButton, Icons.pause_rounded), findsNothing);
    expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);

    final artifacts = debugShotDirectory();
    if (artifacts == null) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('downloads-tab-root')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${artifacts.path}/downloads_paused_not_running.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });

  testWidgets(
    'queued download shows an hourglass and no calculating placeholders',
    (tester) async {
      await _prepareArtworkStorage(tester);
      const logicalId = 'queued-logical-id';
      final queued = _item(
        taskId: 'queued-task',
        timestamp: 5,
        status: TaskStatus.enqueued,
        logicalId: logicalId,
      );
      await tester.pumpWidget(
        _downloadsApp(
          [queued],
          progressData: const <String, DownloadProgressData>{
            logicalId: DownloadProgressData(
              taskId: 'queued-task',
              progress: 0,
              status: TaskStatus.enqueued,
            ),
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('في الانتظار...'), findsOneWidget);
      expect(find.byIcon(Icons.hourglass_top_rounded), findsOneWidget);
      expect(find.byIcon(Icons.download_rounded), findsNothing);
      // Cards never show a per-download speed or remaining time.
      expect(find.text('جارٍ الحساب…'), findsNothing);
    },
  );

  testWidgets('running download card shows no speed or remaining time', (
    tester,
  ) async {
    await _prepareArtworkStorage(tester);
    const logicalId = 'running-logical-id';
    final running = _item(
      taskId: 'running-task',
      timestamp: 5,
      status: TaskStatus.running,
      logicalId: logicalId,
    );
    await tester.pumpWidget(
      _downloadsApp(
        [running],
        progressData: const <String, DownloadProgressData>{
          logicalId: DownloadProgressData(
            taskId: 'running-task',
            progress: 0.4,
            status: TaskStatus.running,
          ),
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byIcon(Icons.download_rounded), findsOneWidget);
    expect(find.byIcon(Icons.hourglass_top_rounded), findsNothing);
    // Per-download speed/ETA were removed from the card entirely; the only
    // speed in the app is the session total in the strip above the list.
    expect(find.textContaining('KB/s'), findsNothing);
    expect(find.textContaining('MB/s'), findsNothing);
  });

  testWidgets('session strip shows the batch position and total speed', (
    tester,
  ) async {
    await _prepareArtworkStorage(tester);
    addTearDown(
      () => downloadSessionSummaryNotifier.value =
          const DownloadSessionSummaryV2.inactive(),
    );
    const logicalId = 'strip-logical-id';
    final running = _item(
      taskId: 'strip-task',
      timestamp: 5,
      status: TaskStatus.running,
      logicalId: logicalId,
    );
    await tester.pumpWidget(
      _downloadsApp([
        running,
      ], progressData: const <String, DownloadProgressData>{}),
    );
    await tester.pump();
    expect(find.textContaining('يتم تنزيل'), findsNothing);

    downloadSessionSummaryNotifier.value = const DownloadSessionSummaryV2(
      currentIndex: 1,
      batchTotal: 2,
      totalSpeedBytesPerSecond: 274000,
    );
    await tester.pump();
    expect(find.text('يتم تنزيل 1 من 2'), findsOneWidget);
    expect(find.text('274KB/s'), findsOneWidget);

    downloadSessionSummaryNotifier.value =
        const DownloadSessionSummaryV2.inactive();
    await tester.pump();
    expect(find.textContaining('يتم تنزيل'), findsNothing);
    expect(find.text('274KB/s'), findsNothing);
  });
}
