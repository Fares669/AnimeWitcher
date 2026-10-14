import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_artwork_store_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/core/storage/episode_watch_repository.dart';
import 'package:animewitcher/features/details/presentation/playback_launcher.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/widgets/completed_download_episode_card.dart';
import 'package:animewitcher/features/library/presentation/widgets/downloads_tab.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/loading_indicator.dart';
import 'package:animewitcher/shared/widgets/underline_segment_tabs.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../core/services/download_v2/download_v2_test_support.dart';
import '../../../support/manga_image_fixtures.dart';
import '../../../support/memory_storage_service.dart';
import '../../../support/widget_completion.dart';

class _LoadingDownloads extends DownloadsNotifier {
  final pending = Completer<List<DownloadItem>>();
  @override
  Future<List<DownloadItem>> build() => pending.future;

  void fail() {
    state = AsyncError(
      StateError('offline startup failed'),
      StackTrace.current,
    );
  }
}

class _RefreshDownloads extends DownloadsNotifier {
  @override
  Future<List<DownloadItem>> build() async => [
    DownloadItem(
      task: DownloadTask(
        taskId: 'saved-row',
        url: 'https://example.test/video.mp4',
      ),
      status: TaskStatus.complete,
      progress: 1,
      item: MultimediaItem(
        title: 'Saved show',
        url: 'anime://saved-show',
        posterUrl: '',
      ),
      timestamp: 1,
    ),
  ];

  void startRefresh() => state = const AsyncLoading();
  void fail() => state = AsyncError(
    StateError('offline startup failed'),
    StackTrace.current,
  );
}

class _Metadata extends MemoryStorageService {
  final rows = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, Map<String, dynamic>>> getAllDownloadMetadata() async =>
      rows;
}

class _History implements HistoryRepository {
  @override
  List<HistoryItem> getWatchHistory() => const [];
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

class _StalledGateway implements BackgroundDownloaderGateway {
  final initialization = Completer<void>();
  int initializationCalls = 0;
  @override
  Future<void> initialize() {
    initializationCalls++;
    return initialization.future;
  }

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => const [];
  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => null;
  @override
  Future<void> removeTracking(String taskId) async {}
  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async =>
      throw StateError('Transport must remain blocked in this regression');
}

class _Playback extends PlaybackLauncher {
  _Playback(super.ref);
  final played = <String>[];
  @override
  Future<void> play(
    BuildContext context,
    String url, {
    required MultimediaItem baseItem,
    MultimediaItem? detailedItem,
    Episode? episode,
    StreamResult? preselectedSource,
    bool loadEpisodeArtwork = false,
    Future<String?> Function()? resolveUrl,
    Future<void> Function()? onMissingFile,
  }) async {
    final playableUrl = resolveUrl == null ? url : await resolveUrl();
    if (playableUrl == null) {
      await onMissingFile?.call();
      return;
    }
    played.add(playableUrl);
  }
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: const MaterialApp(
    locale: Locale('ar'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SafeArea(child: DownloadsTab())),
  ),
);

Future<void> _switchTab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _awaitArtwork(WidgetTester tester) async {
  for (final builder
      in tester
          .widgetList<FutureBuilder<File?>>(
            find.byWidgetPredicate((widget) => widget is FutureBuilder<File?>),
          )
          .toList(growable: false)) {
    final future = builder.future;
    if (future != null) {
      await pumpUntilFuture(tester, future, 'completed artwork lookup');
    }
  }
  await tester.pump();
}

LogicalDownloadRecordV2 _record(
  String unit,
  String path, {
  bool complete = false,
}) {
  final id = logicalDownloadIdFor(
    animeId: 'anime://saved-show',
    episodeKey: unit,
    variantKey: 'original',
  );
  return LogicalDownloadRecordV2(
    schemaVersion: kLogicalDownloadSchemaVersionV2,
    logicalId: id,
    mediaId: 'anime://saved-show',
    unitKey: unit,
    variantKey: 'original',
    generation: 1,
    taskId: taskIdForGeneration(id, 1),
    intent: DownloadUserIntent.active,
    destinationPath: path,
    sourceDescriptor: const {},
    expectedBytes: complete ? 3 : null,
    updatedAtMillis: 1,
    completedAtMillis: complete ? 1 : null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalPaths = PathProviderPlatform.instance;
  late Directory artworkRoot;
  setUpAll(() async {
    artworkRoot = await Directory.systemTemp.createTemp('aw-offline-artwork-');
    PathProviderPlatform.instance = _Paths(artworkRoot.path);
    try {
      await DefaultCacheManager().getFileFromCache('offline-downloads-fixture');
    } finally {
      PathProviderPlatform.instance = originalPaths;
    }
  });
  setUp(() => PathProviderPlatform.instance = _Paths(artworkRoot.path));
  tearDown(() => PathProviderPlatform.instance = originalPaths);
  tearDownAll(() => artworkRoot.delete(recursive: true));

  testWidgets(
    'tabs stay clickable while active downloads never finish loading',
    (tester) async {
      final container = ProviderContainer(
        overrides: [downloadsProvider.overrideWith(_LoadingDownloads.new)],
      );
      try {
        await tester.pumpWidget(_app(container));
        await tester.pump();
        expect(find.byType(FilterStyleTabBar).hitTestable(), findsOneWidget);
        expect(find.text('التنزيلات').hitTestable(), findsOneWidget);
        expect(find.text('المكتملة').hitTestable(), findsOneWidget);
        expect(
          tester.getTopLeft(find.byType(FilterStyleTabBar)).dy,
          lessThan(80),
        );
        expect(find.byType(AppLoadingIndicator).hitTestable(), findsOneWidget);

        await _switchTab(tester, 'المكتملة');
        expect(find.byType(AppLoadingIndicator).hitTestable(), findsNothing);
        expect(
          find
              .text(
                AppLocalizations.of(tester.element(find.byType(DownloadsTab)))!
                    .noCompletedDownloadsYet,
              )
              .hitTestable(),
          findsOneWidget,
        );

        await _switchTab(tester, 'التنزيلات');
        expect(find.byType(AppLoadingIndicator).hitTestable(), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      }
    },
  );

  testWidgets('cold errors leave both tabs clickable and Completed usable', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [downloadsProvider.overrideWith(_LoadingDownloads.new)],
    );
    try {
      await tester.pumpWidget(_app(container));
      (container.read(downloadsProvider.notifier) as _LoadingDownloads).fail();
      await tester.pump();
      expect(container.read(downloadsProvider).hasValue, isFalse);
      expect(find.byType(FilterStyleTabBar).hitTestable(), findsOneWidget);
      expect(
        find.textContaining('offline startup failed').hitTestable(),
        findsOneWidget,
      );
      await _switchTab(tester, 'المكتملة');
      expect(
        find.textContaining('offline startup failed').hitTestable(),
        findsNothing,
      );
      expect(find.text('لا توجد تنزيلات مكتملة').hitTestable(), findsOneWidget);
      expect(find.byType(AppLoadingIndicator).hitTestable(), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    }
  });

  testWidgets('Completed keeps previous local rows through refresh and error', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        downloadsProvider.overrideWith(_RefreshDownloads.new),
        storageServiceProvider.overrideWithValue(_Metadata()),
      ],
    );
    try {
      await pumpUntilFuture(
        tester,
        container.read(downloadsProvider.future),
        'saved rows',
      );
      await tester.pumpWidget(_app(container));
      final notifier =
          container.read(downloadsProvider.notifier) as _RefreshDownloads;
      notifier.startRefresh();
      await tester.pump();
      expect(find.byType(AppLoadingIndicator).hitTestable(), findsOneWidget);
      await _switchTab(tester, 'المكتملة');
      await pumpUntil(
        tester,
        () => find.text('Saved show').hitTestable().evaluate().isNotEmpty,
        'completed rows during refresh',
      );
      await _awaitArtwork(tester);
      expect(find.byType(AppLoadingIndicator).hitTestable(), findsNothing);
      notifier.fail();
      await tester.pump();
      expect(find.text('Saved show').hitTestable(), findsOneWidget);
      await _switchTab(tester, 'التنزيلات');
      expect(
        find.textContaining('offline startup failed').hitTestable(),
        findsOneWidget,
      );
      await _switchTab(tester, 'المكتملة');
      expect(find.text('Saved show').hitTestable(), findsOneWidget);
      await _awaitArtwork(tester);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    }
  });

  testWidgets(
    'durable completed cards and playback ignore stalled transport startup',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('aw-offline-tabs-'),
      ))!;
      final previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      final store = InMemoryLogicalDownloadStoreV2();
      final storage = _Metadata();
      final gateway = _StalledGateway();
      final resolver = StaticSourceResolverV2();
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: resolver,
      );
      final completed = _record(
        'episode://1',
        '${root.path}/saved.mp4',
        complete: true,
      );
      final active = _record('episode://2', '${root.path}/active.mp4');
      final unknown = _record(
        'episode://3',
        '${root.path}/unknown.mp4',
        complete: true,
      );
      final show = MultimediaItem(
        title: 'Saved show',
        url: 'anime://saved-show',
        posterUrl: '',
      );
      final episode = Episode(
        name: 'Saved title',
        url: completed.unitKey,
        episode: 1,
      );
      late File? poster;
      await tester.runAsync(() async {
        await File(completed.destinationPath).writeAsBytes([1, 2, 3]);
        for (final record in [completed, active, unknown]) {
          await store.put(record);
        }
        storage.rows[completed.logicalId.value] = {
          'logicalId': completed.logicalId.value,
          'item': show.toJson(),
          'episode': episode.toJson(),
          'timestamp': 1,
        };
        storage.rows[active.logicalId.value] = {
          'logicalId': active.logicalId.value,
          'item': show.toJson(),
          'episode': Episode(
            name: 'Downloading',
            url: active.unitKey,
            episode: 2,
          ).toJson(),
          'timestamp': 2,
        };
        final artwork = DownloadArtworkStoreV2(
          supportDirectory: () async => root,
          cachedFileForUrl: (_) async => null,
          fetchBytes: (_) async => tinyMangaPng,
        );
        poster = await artwork.ensure(
          logicalId: completed.logicalId.value,
          kind: DownloadArtworkKindV2.poster,
          url: 'https://example.test/poster.png',
        );
        await artwork.ensure(
          logicalId: completed.logicalId.value,
          kind: DownloadArtworkKindV2.episode,
          url: 'https://example.test/episode.png',
        );
      });
      late _Playback playback;
      final container = ProviderContainer(
        overrides: [
          downloadManagerV2Provider.overrideWithValue(manager),
          logicalDownloadStoreV2Provider.overrideWithValue(store),
          storageServiceProvider.overrideWithValue(storage),
          historyRepositoryProvider.overrideWithValue(_History()),
          episodeWatchRepositoryProvider.overrideWithValue(_Watch()),
          playbackLauncherProvider.overrideWith(
            (ref) => playback = _Playback(ref),
          ),
        ],
      );
      try {
        final rows = await pumpUntilFuture(
          tester,
          container.read(downloadsProvider.future),
          'durable local download projection',
        );
        expect(rows, hasLength(2));
        expect(
          rows
              .where((item) => item.status == TaskStatus.complete)
              .single
              .episode
              ?.name,
          'Saved title',
        );
        expect(
          rows.any((item) => item.logicalId == unknown.logicalId.value),
          isFalse,
        );
        expect(gateway.initializationCalls, 1);
        expect(gateway.initialization.isCompleted, isFalse);
        expect(resolver.calls, 0);
        container.read(playbackLauncherProvider);
        await tester.pumpWidget(_app(container));
        await _switchTab(tester, 'المكتملة');
        await pumpUntil(
          tester,
          () => find.text('Saved show').hitTestable().evaluate().isNotEmpty,
          'offline completed group',
        );
        bool usesSavedPoster() =>
            tester.widgetList<Image>(find.byType(Image)).any((widget) {
              final provider = widget.image;
              final image = provider is ResizeImage
                  ? provider.imageProvider
                  : provider;
              return image is FileImage && image.file.path == poster?.path;
            });
        await pumpUntil(tester, usesSavedPoster, 'cached completed poster');
        await tester.tap(find.text('Saved show'));
        final card = find.byKey(ValueKey(completed.taskId));
        await pumpUntil(
          tester,
          () => card.hitTestable().evaluate().isNotEmpty,
          'offline episode card',
        );
        expect(find.byType(CompletedDownloadEpisodeCard), findsOneWidget);
        await _awaitArtwork(tester);
        await tester.tap(card);
        await pumpUntil(
          tester,
          () => playback.played.isNotEmpty,
          'verified local playback',
        );
        expect(playback.played, [completed.destinationPath]);
        expect(gateway.initialization.isCompleted, isFalse);
        expect(resolver.calls, 0);
        gateway.initialization.completeError(
          StateError('offline startup failed'),
        );
        await pumpUntil(
          tester,
          () => container.read(downloadsProvider).hasError,
          'transport initialization error',
        );
        expect(find.byType(CompletedDownloadEpisodeCard), findsOneWidget);
        expect(card.hitTestable(), findsOneWidget);
        await _switchTab(tester, 'التنزيلات');
        expect(
          find.textContaining('offline startup failed').hitTestable(),
          findsOneWidget,
        );
        await _switchTab(tester, 'المكتملة');
        expect(find.text('Saved show').hitTestable(), findsOneWidget);
        await tester.tap(find.text('Saved show'));
        await pumpUntil(
          tester,
          () => card.hitTestable().evaluate().isNotEmpty,
          'completed card after transport error',
        );
        await _awaitArtwork(tester);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await manager.dispose();
        PathProviderPlatform.instance = previousPaths;
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );
}
