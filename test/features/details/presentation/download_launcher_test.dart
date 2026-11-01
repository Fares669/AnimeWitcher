import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/services/notification_service.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/details/presentation/download_launcher.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/loading_dialog.dart';
import 'package:animewitcher/shared/widgets/loading_indicator.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';
import '../../../support/test_fonts.dart';
import '../../../support/debug_shots.dart';

const _shotKey = ValueKey('download-server-loading');

class _StubExtensions extends ExtensionManager {
  _StubExtensions(this._providers);

  final List<AnimeWitcherProvider> _providers;

  @override
  List<AnimeWitcherProvider> build() => _providers;
}

class _FakeDownloadSource extends AnimeWitcherProvider {
  _FakeDownloadSource(this.sources);

  final Completer<List<StreamResult>> sources;
  int sourceLoads = 0;

  @override
  String get packageName => 'fake.download';

  @override
  String get name => 'Fake';

  @override
  String get mainUrl => 'https://example.test';

  @override
  String get version => '1';

  @override
  List<String> get languages => const <String>['ar'];

  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.anime};

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async {
    return const <String, List<MultimediaItem>>{};
  }

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    return const <MultimediaItem>[];
  }

  @override
  Future<MultimediaItem> getDetails(String url) async {
    return MultimediaItem(title: 'Details', url: url, posterUrl: '');
  }

  @override
  Future<List<StreamResult>> loadStreamSources(String url) {
    sourceLoads++;
    return sources.future;
  }

  @override
  Future<List<StreamResult>> loadStreams(String url) async {
    return const <StreamResult>[];
  }
}

class _BatchDownloadSource extends AnimeWitcherProvider {
  _BatchDownloadSource({
    this.sourcesByEpisode = const {},
    this.resolvedBySource = const {},
    this.sourceLoaders = const {},
  });

  final Map<String, List<StreamResult>> sourcesByEpisode;
  final Map<String, List<StreamResult>> resolvedBySource;
  final Map<String, Future<List<StreamResult>> Function()> sourceLoaders;
  final Map<String, int> sourceCallsByEpisode = <String, int>{};
  final List<String> sourceCallOrder = <String>[];
  final List<String> resolvedUrls = <String>[];
  int resolutionCalls = 0;

  @override
  String get packageName => 'fake.batch.download';

  @override
  String get name => 'Fake Batch';

  @override
  String get mainUrl => 'https://example.test';

  @override
  String get version => '1';

  @override
  List<String> get languages => const <String>['ar'];

  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.anime};

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => const {};

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => const [];

  @override
  Future<MultimediaItem> getDetails(String url) async =>
      MultimediaItem(title: 'Details', url: url, posterUrl: '');

  @override
  Future<List<StreamResult>> loadStreamSources(String url) async {
    sourceCallOrder.add(url);
    sourceCallsByEpisode.update(url, (value) => value + 1, ifAbsent: () => 1);
    final loader = sourceLoaders[url];
    if (loader != null) return loader();
    return sourcesByEpisode[url] ?? const <StreamResult>[];
  }

  @override
  Future<List<StreamResult>> loadStreams(String url) async {
    resolutionCalls++;
    resolvedUrls.add(url);
    return resolvedBySource[url] ?? const <StreamResult>[];
  }
}

class _DelayedLogicalDownloadStore implements LogicalDownloadStoreV2 {
  final Completer<List<LogicalDownloadRecordV2>> allCompleter = Completer();

  @override
  Future<List<LogicalDownloadRecordV2>> all() => allCompleter.future;

  @override
  Future<LogicalDownloadRecordV2?> get(DownloadLogicalId id) async => null;

  @override
  Future<void> put(LogicalDownloadRecordV2 record) async {}

  @override
  Future<void> remove(DownloadLogicalId id) async {}

  @override
  Future<LogicalDownloadRecordV2?> mutate(
    DownloadLogicalId id,
    LogicalDownloadRecordV2? Function(LogicalDownloadRecordV2? current) change,
  ) async => change(null);
}

Future<void> _writeShot(WidgetTester tester, String filename) async {
  final artifacts = debugShotDirectory();
  if (artifacts == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_shotKey),
  );
  final image = await boundary.toImage(pixelRatio: 2);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File('${artifacts.path}/$filename')
      .writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'single download keeps server filename while batch forces episode name',
    () {
      final item = MultimediaItem(title: 'Show', url: 'show', posterUrl: '');
      final episode = Episode(
        name: 'الحلقة 9',
        url: 'ep9',
        episode: 9,
        serverName: 'الحلقة 9',
      );

      expect(
        downloadFilenameV2(
          extension: '.mp4',
          serverFilename: 'server-file.mp4',
          item: item,
          episode: episode,
          quality: '1080p',
          forceEpisodeFilename: false,
        ),
        'server-file.mp4',
      );
      expect(
        downloadFilenameV2(
          extension: '.mp4',
          serverFilename: 'server-file.mp4',
          item: item,
          episode: episode,
          quality: '1080p',
          forceEpisodeFilename: true,
        ),
        isNot('server-file.mp4'),
      );
    },
  );

  testWidgets('batch skips an episode already present in V2', (tester) async {
    final store = InMemoryLogicalDownloadStoreV2();
    const variantKey = 'default|1080p';
    await store.put(
      LogicalDownloadRecordV2(
        schemaVersion: kLogicalDownloadSchemaVersionV2,
        logicalId: logicalDownloadIdFor(
          animeId: 'show',
          episodeKey: 'ep1',
          variantKey: variantKey,
        ),
        mediaKind: DownloadMediaKind.videoEpisode,
        mediaId: 'show',
        unitKey: 'ep1',
        variantKey: variantKey,
        generation: 1,
        taskId: 'existing-ep1',
        intent: DownloadUserIntent.active,
        destinationPath: 'Downloads/anime/Show/ep1.mp4',
        sourceDescriptor: const <String, Object?>{},
        updatedAtMillis: 1,
      ),
    );
    final provider = _BatchDownloadSource(
      sourcesByEpisode: const {
        'ep1': [StreamResult(url: 'ep1-1080', source: 'PD', quality: '1080p')],
        'ep2': [StreamResult(url: 'ep2-1080', source: 'PD', quality: '1080p')],
      },
    );
    late BuildContext launchContext;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(MemoryStorageService()),
          logicalDownloadStoreV2Provider.overrideWithValue(store),
          extensionManagerProvider.overrideWith(
            () => _StubExtensions(<AnimeWitcherProvider>[provider]),
          ),
          activeProviderProvider.overrideWithValue(provider),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                launchContext = context;
                return const Text('ready');
              },
            ),
          ),
        ),
      ),
    );

    final launcher = ProviderScope.containerOf(launchContext)
        .read(downloadLauncherProvider);
    unawaited(
      launcher.launchBatch(
        launchContext,
        MultimediaItem(
          title: 'Show',
          url: 'show',
          posterUrl: '',
          provider: provider.packageName,
        ),
        <Episode>[
          Episode(name: '', url: 'ep1', episode: 1, season: 1),
          Episode(name: '', url: 'ep2', episode: 2, season: 1),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(provider.sourceCallsByEpisode['ep1'] ?? 0, 0);
    expect(provider.sourceCallsByEpisode['ep2'], 1);
    expect(find.text('1080p'), findsOneWidget);

    Navigator.of(tester.element(find.text('PD'))).pop();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'batch stops if the details context is disposed during V2 lookup',
    (tester) async {
      final store = _DelayedLogicalDownloadStore();
      final provider = _BatchDownloadSource(
        sourcesByEpisode: const {
          'ep1': [
            StreamResult(url: 'ep1-1080', source: 'PD', quality: '1080p'),
          ],
        },
      );
      late BuildContext launchContext;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageServiceProvider.overrideWithValue(MemoryStorageService()),
            logicalDownloadStoreV2Provider.overrideWithValue(store),
            extensionManagerProvider.overrideWith(
              () => _StubExtensions(<AnimeWitcherProvider>[provider]),
            ),
            activeProviderProvider.overrideWithValue(provider),
          ],
          child: MaterialApp(
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) {
                launchContext = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      unawaited(
        ProviderScope.containerOf(launchContext)
            .read(downloadLauncherProvider)
            .launchBatch(
              launchContext,
              MultimediaItem(
                title: 'Show',
                url: 'show',
                posterUrl: '',
                provider: provider.packageName,
              ),
              <Episode>[Episode(name: '', url: 'ep1', episode: 1)],
            ),
      );
      await tester.pumpWidget(const SizedBox());
      store.allCompleter.complete(const <LogicalDownloadRecordV2>[]);
      await tester.pumpAndSettle();

      expect(provider.sourceCallsByEpisode, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('batch reports when selected episodes have no common source', (
    tester,
  ) async {
    final provider = _BatchDownloadSource(
      sourcesByEpisode: const {
        'ep1': [StreamResult(url: 'ep1-1080', source: 'PD', quality: '1080p')],
        'ep2': [StreamResult(url: 'ep2-1080', source: 'MF', quality: '1080p')],
      },
    );
    final notifications = NotificationService();
    addTearDown(notifications.dispose);
    late BuildContext launchContext;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(MemoryStorageService()),
          logicalDownloadStoreV2Provider.overrideWithValue(
            InMemoryLogicalDownloadStoreV2(),
          ),
          notificationServiceProvider.overrideWithValue(notifications),
          extensionManagerProvider.overrideWith(
            () => _StubExtensions(<AnimeWitcherProvider>[provider]),
          ),
          activeProviderProvider.overrideWithValue(provider),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                launchContext = context;
                return const Text('ready');
              },
            ),
          ),
        ),
      ),
    );

    await ProviderScope.containerOf(launchContext)
        .read(downloadLauncherProvider)
        .launchBatch(
          launchContext,
          MultimediaItem(
            title: 'Show',
            url: 'show',
            posterUrl: '',
            provider: provider.packageName,
          ),
          <Episode>[
            Episode(name: '', url: 'ep1', episode: 1),
            Episode(name: '', url: 'ep2', episode: 2),
          ],
        );
    await tester.pumpAndSettle();

    expect(notifications.toasts, isNotEmpty);
    expect(notifications.toasts.last.message, contains('لا توجد جودة وسيرفر مشتركان'));
    expect(find.text('PD'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('batch sorts by season then episode before scanning sources', (
    tester,
  ) async {
    final provider = _BatchDownloadSource(
      sourcesByEpisode: const {
        's1e1': [
          StreamResult(url: 's1e1-1080', source: 'PD', quality: '1080p'),
        ],
        's1e2': [
          StreamResult(url: 's1e2-1080', source: 'PD', quality: '1080p'),
        ],
        's2e1': [
          StreamResult(url: 's2e1-1080', source: 'PD', quality: '1080p'),
        ],
      },
    );
    late BuildContext launchContext;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(MemoryStorageService()),
          logicalDownloadStoreV2Provider.overrideWithValue(
            InMemoryLogicalDownloadStoreV2(),
          ),
          extensionManagerProvider.overrideWith(
            () => _StubExtensions(<AnimeWitcherProvider>[provider]),
          ),
          activeProviderProvider.overrideWithValue(provider),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                launchContext = context;
                return const Text('ready');
              },
            ),
          ),
        ),
      ),
    );

    unawaited(
      ProviderScope.containerOf(launchContext)
          .read(downloadLauncherProvider)
          .launchBatch(
            launchContext,
            MultimediaItem(
              title: 'Show',
              url: 'show',
              posterUrl: '',
              provider: provider.packageName,
            ),
            <Episode>[
              Episode(name: '', url: 's2e1', season: 2, episode: 1),
              Episode(name: '', url: 's1e2', season: 1, episode: 2),
              Episode(name: '', url: 's1e1', season: 1, episode: 1),
            ],
          ),
    );
    await tester.pumpAndSettle();

    expect(provider.sourceCallOrder, ['s1e1', 's1e2', 's2e1']);
    Navigator.of(tester.element(find.text('PD'))).pop();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'batch groups servers by quality and resolves only the chosen pair',
    (tester) async {
      final provider = _BatchDownloadSource(
        sourcesByEpisode: const {
          'ep1': [
            StreamResult(
              url: 'ep1-pd',
              source: 'PD',
              quality: '1080p',
              requiresResolution: true,
            ),
            StreamResult(
              url: 'ep1-pd-720',
              source: 'PD',
              quality: '720p',
              requiresResolution: true,
            ),
            StreamResult(
              url: 'ep1-mf',
              source: 'MF',
              quality: '720p',
              requiresResolution: true,
            ),
          ],
          'ep2': [
            StreamResult(
              url: 'ep2-pd',
              source: 'PD',
              quality: '1080p',
              requiresResolution: true,
            ),
            StreamResult(
              url: 'ep2-pd-720',
              source: 'PD',
              quality: '720p',
              requiresResolution: true,
            ),
            StreamResult(
              url: 'ep2-mf',
              source: 'MF',
              quality: '720p',
              requiresResolution: true,
            ),
          ],
        },
        resolvedBySource: const {
          'ep1-pd': [
            StreamResult(url: 'ep1-1080', source: 'PD', quality: '1080p'),
            StreamResult(url: 'ep1-720', source: 'PD', quality: '720p'),
          ],
          'ep2-pd': [
            StreamResult(url: 'ep2-1080', source: 'PD', quality: '1080p'),
          ],
        },
      );
      late BuildContext launchContext;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageServiceProvider.overrideWithValue(MemoryStorageService()),
            logicalDownloadStoreV2Provider.overrideWithValue(
              InMemoryLogicalDownloadStoreV2(),
            ),
            extensionManagerProvider.overrideWith(
              () => _StubExtensions(<AnimeWitcherProvider>[provider]),
            ),
            activeProviderProvider.overrideWithValue(provider),
          ],
          child: MaterialApp(
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  launchContext = context;
                  return const Text('ready');
                },
              ),
            ),
          ),
        ),
      );
      final launcher = ProviderScope.containerOf(launchContext)
          .read(downloadLauncherProvider);
      final item = MultimediaItem(
        title: 'Show',
        url: 'show',
        posterUrl: '',
        provider: provider.packageName,
      );
      unawaited(
        launcher.launchBatch(launchContext, item, <Episode>[
          Episode(name: '', url: 'ep2', episode: 2, season: 1),
          Episode(name: '', url: 'ep1', episode: 1, season: 1),
        ]),
      );
      await tester.pumpAndSettle();

      expect(provider.resolutionCalls, 0);
      expect(find.text('1080p'), findsOneWidget);
      expect(find.text('PD'), findsNWidgets(2));
      expect(find.text('MF'), findsOneWidget);
      expect(find.text('720p'), findsOneWidget);
      expect(find.text('متعدد'), findsNothing);

      await tester.tap(find.text('PD').first);
      await tester.pumpAndSettle();
      expect(provider.resolutionCalls, 0);
      expect(find.text('ep1-pd'), findsNothing);
      final l10n = AppLocalizations.of(launchContext)!;
      await tester.tap(find.widgetWithText(FilledButton, l10n.downloadNow));
      await tester.pumpAndSettle();
      expect(provider.resolvedUrls, ['ep1-pd', 'ep2-pd']);
      expect(provider.sourceCallOrder, ['ep1', 'ep2']);
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets('batch source scan reports progress as each episode finishes', (
    tester,
  ) async {
    final first = Completer<List<StreamResult>>();
    final second = Completer<List<StreamResult>>();
    final provider = _BatchDownloadSource(
      sourceLoaders: {'ep1': () => first.future, 'ep2': () => second.future},
    );
    late BuildContext launchContext;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(MemoryStorageService()),
          logicalDownloadStoreV2Provider.overrideWithValue(
            InMemoryLogicalDownloadStoreV2(),
          ),
          extensionManagerProvider.overrideWith(
            () => _StubExtensions(<AnimeWitcherProvider>[provider]),
          ),
          activeProviderProvider.overrideWithValue(provider),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                launchContext = context;
                return const Text('ready');
              },
            ),
          ),
        ),
      ),
    );
    final launcher = ProviderScope.containerOf(launchContext)
        .read(downloadLauncherProvider);
    unawaited(
      launcher.launchBatch(
        launchContext,
        MultimediaItem(
          title: 'Show',
          url: 'show',
          posterUrl: '',
          provider: provider.packageName,
        ),
        <Episode>[
          Episode(name: '', url: 'ep1', episode: 1),
          Episode(name: '', url: 'ep2', episode: 2),
        ],
      ),
    );
    await tester.pump();

    expect(find.text('جاري فحص السيرفرات: 0/2'), findsOneWidget);
    first.complete(const [
      StreamResult(url: 'ep1-1080', source: 'PD', quality: '1080p'),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('جاري فحص السيرفرات: 1/2'), findsOneWidget);

    second.complete(const [
      StreamResult(url: 'ep2-1080', source: 'PD', quality: '1080p'),
    ]);
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('PD'))).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('batch source scan retries only failed episodes', (tester) async {
    var secondAttempts = 0;
    final provider = _BatchDownloadSource(
      sourceLoaders: {
        'ep1': () async => const [
          StreamResult(url: 'ep1-1080', source: 'PD', quality: '1080p'),
        ],
        'ep2': () async {
          secondAttempts++;
          if (secondAttempts == 1) throw StateError('temporary source failure');
          return const [
            StreamResult(url: 'ep2-1080', source: 'PD', quality: '1080p'),
          ];
        },
      },
    );
    final notifications = NotificationService();
    addTearDown(notifications.dispose);
    late BuildContext launchContext;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(MemoryStorageService()),
          logicalDownloadStoreV2Provider.overrideWithValue(
            InMemoryLogicalDownloadStoreV2(),
          ),
          notificationServiceProvider.overrideWithValue(notifications),
          extensionManagerProvider.overrideWith(
            () => _StubExtensions(<AnimeWitcherProvider>[provider]),
          ),
          activeProviderProvider.overrideWithValue(provider),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                launchContext = context;
                return const Text('ready');
              },
            ),
          ),
        ),
      ),
    );
    final launcher = ProviderScope.containerOf(launchContext)
        .read(downloadLauncherProvider);
    unawaited(
      launcher.launchBatch(
        launchContext,
        MultimediaItem(
          title: 'Show',
          url: 'show',
          posterUrl: '',
          provider: provider.packageName,
        ),
        <Episode>[
          Episode(name: '', url: 'ep1', episode: 1),
          Episode(name: '', url: 'ep2', episode: 2),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('إعادة المحاولة'), findsOneWidget);
    expect(provider.sourceCallsByEpisode['ep1'], 1);
    expect(provider.sourceCallsByEpisode['ep2'], 1);

    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();
    expect(provider.sourceCallsByEpisode['ep1'], 1);
    expect(provider.sourceCallsByEpisode['ep2'], 2);
    expect(find.text('1080p'), findsOneWidget);

    Navigator.of(tester.element(find.text('PD'))).pop();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'duplicate launch opens one server sheet and loads sources once',
    (tester) async {
      final pending = Completer<List<StreamResult>>();
      final source = _FakeDownloadSource(pending);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(TestFonts.loadWalkthroughFonts);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageServiceProvider.overrideWithValue(MemoryStorageService()),
            extensionManagerProvider.overrideWith(
              () => _StubExtensions(<AnimeWitcherProvider>[source]),
            ),
            activeProviderProvider.overrideWithValue(source),
          ],
          child: RepaintBoundary(
            key: _shotKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
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
                ),
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) {
                    return TextButton(
                      onPressed: () {
                        unawaited(
                          ProviderScope.containerOf(context)
                              .read(downloadLauncherProvider)
                              .launch(
                                context,
                                MultimediaItem(
                                  title: 'Show',
                                  url: 'https://example.test/show',
                                  posterUrl: '',
                                ),
                                episode: Episode(
                                  name: '',
                                  url: 'https://example.test/ep9',
                                  episode: 9,
                                  serverName: 'الحلقة 9',
                                ),
                              ),
                        );
                      },
                      child: const Text('download'),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );

      final launchContext = tester.element(find.text('download'));
      final launcher = ProviderScope.containerOf(launchContext)
          .read(downloadLauncherProvider);
      final item = MultimediaItem(
        title: 'Show',
        url: 'https://example.test/show',
        posterUrl: '',
        episodes: <Episode>[
          Episode(
            name: '',
            url: 'https://example.test/ep9',
            episode: 9,
            serverName: 'الحلقة 9',
          ),
        ],
      );
      unawaited(
        launcher.launch(
          launchContext,
          item,
          episodeUrl: 'https://example.test/ep9',
        ),
      );
      unawaited(
        launcher.launch(
          launchContext,
          item,
          episodeUrl: 'https://example.test/ep9',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(source.sourceLoads, 1);
      expect(find.byType(LoadingDialog), findsNothing);
      expect(find.text('جارٍ الحل...'), findsNothing);
      expect(find.byType(AppLoadingIndicator), findsOneWidget);
      expect(find.text('جارٍ التحميل...'), findsOneWidget);
      expect(find.text('الحلقة 9'), findsOneWidget);

      await tester.runAsync(
        () => _writeShot(tester, 'download_server_sheet_loading.png'),
      );

      pending.complete(const <StreamResult>[
        StreamResult(url: 'src-pd', source: 'PD', quality: '1080'),
      ]);
      await tester.pumpAndSettle();

      expect(find.text('جارٍ التحميل...'), findsNothing);
      expect(find.text('PD'), findsOneWidget);
      expect(find.byIcon(Icons.file_download_outlined), findsOneWidget);

      // A different episode can launch while the first selection is still open.
      unawaited(
        launcher.launch(
          launchContext,
          item,
          episodeUrl: 'https://example.test/ep10',
        ),
      );
      await tester.pumpAndSettle();
      expect(source.sourceLoads, 2);
      Navigator.of(tester.element(find.text('PD').last)).pop();
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('PD'))).pop();
      await tester.pumpAndSettle();

      // Canceling the picker releases this episode's guard for another attempt.
      unawaited(
        launcher.launch(
          launchContext,
          item,
          episodeUrl: 'https://example.test/ep9',
        ),
      );
      await tester.pumpAndSettle();
      expect(source.sourceLoads, 3);
      expect(find.text('PD'), findsOneWidget);
      Navigator.of(tester.element(find.text('PD'))).pop();
      await tester.pumpAndSettle();
    },
  );
}
