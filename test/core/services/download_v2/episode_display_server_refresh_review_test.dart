import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/services/notification_service.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/network/dio_client_provider.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/utils/episode_label.dart';
import 'package:animewitcher/features/details/presentation/download_launcher.dart';
import 'package:animewitcher/features/details/presentation/downloaded_file_provider.dart';
import 'package:animewitcher/features/details/presentation/playback_launcher.dart';
import 'package:animewitcher/features/details/presentation/stream_source_prefetch.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../support/memory_storage_service.dart';
import '../../../support/widget_completion.dart';

class _Settings extends GeneralSettingsNotifier {
  _Settings(this.auto);
  final bool auto;
  @override
  GeneralSettings build() => GeneralSettings(autoSelectStreamSource: auto);
}

class _Downloads extends DownloadedFiles {
  _Downloads({this.local = false});
  final bool local;
  @override
  Map<String, File?> build() => const {};
  @override
  Future<File?> resolveFile(
    MultimediaItem item, {
    Episode? episode,
    String? logicalId,
  }) async => local ? File('/tmp/saved.mp4') : null;
}

class _CapturedDownload extends MemoryStorageService {
  String? filePath;
  String? logicalId;
  @override
  Future<Map<String, dynamic>?> getDownloadMetadata(String taskId) async =>
      null;
  @override
  Future<void> saveDownloadMetadata(
    String taskId,
    MultimediaItem item, {
    Episode? episode,
    String? trackingUrl,
    String? filePath,
    String? logicalId,
    Map<String, dynamic>? taskSnapshot,
    bool? queueWaiting,
    bool? userPaused,
    double? lastProgress,
    int? lastExpectedBytes,
  }) async {
    this.filePath = filePath;
    this.logicalId = logicalId;
    throw StateError('captured destination before starting transport');
  }
}

class _Paths extends PathProviderPlatform {
  @override
  Future<String?> getDownloadsPath() async => '/tmp/aw-title-launch';
  @override
  Future<String?> getApplicationDocumentsPath() async => '/tmp/aw-title-launch';
}

class _Extensions extends ExtensionManager {
  _Extensions(this.provider);
  final AnimeWitcherProvider provider;
  @override
  List<AnimeWitcherProvider> build() => [provider];
}

class _Sources extends AnimeWitcherProvider {
  final pending = <Completer<List<StreamResult>>>[];
  Completer<List<StreamResult>>? resolution;
  @override
  String get packageName => 'test.fresh.sources';
  @override
  String get name => 'Fresh sources';
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
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => const [];
  @override
  Future<MultimediaItem> getDetails(String url) async =>
      MultimediaItem(title: 'Show', url: url, posterUrl: '');
  @override
  Future<List<StreamResult>> loadStreamSources(String url) {
    final result = Completer<List<StreamResult>>();
    pending.add(result);
    return result.future;
  }

  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      resolution?.future ?? Future.value(const <StreamResult>[]);
}

Future<BuildContext> _shell(
  WidgetTester tester,
  _Sources provider, {
  bool auto = false,
  bool local = false,
  NotificationService? notifications,
  StorageService? storage,
  Dio? dio,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        storageServiceProvider.overrideWithValue(
          storage ?? MemoryStorageService(),
        ),
        if (dio != null) dioClientProvider.overrideWithValue(dio),
        generalSettingsProvider.overrideWith(() => _Settings(auto)),
        downloadedFilesProvider.overrideWith(() => _Downloads(local: local)),
        extensionManagerProvider.overrideWith(() => _Extensions(provider)),
        activeProviderProvider.overrideWithValue(provider),
        if (notifications != null)
          notificationServiceProvider.overrideWith((ref) {
            ref.onDispose(notifications.clearToasts);
            return notifications;
          }),
      ],
      child: MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('episode page')),
                ),
              ),
              child: const Text('details page'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('details page'));
  await tester.pumpAndSettle();
  return tester.element(find.text('episode page'));
}

final _item = MultimediaItem(
  title: 'Show',
  url: 'https://example.test/show',
  posterUrl: '',
);
final _episode = Episode(
  name: '',
  url: 'https://example.test/episode/2',
  episode: 2,
  serverName: 'الحلقة ٢',
);
List<StreamResult> _list(String source) => [
  StreamResult(url: 'https://cdn.test/$source.mp4', source: source),
];

void main() {
  test('native provider preserves the supplied Arabic decimal number outside its integer identity', () async {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: options.uri.path.endsWith('/episodes')
                    ? {
                        'documents': [
                          {
                            'name': 'projects/test/databases/(default)/documents/anime_list/show/episodes/ep2',
                            'fields': {
                              'name': {'stringValue': 'الحلقة ٢.٥'},
                              'episode_number': {'stringValue': '٢.٥'},
                            },
                          },
                        ],
                      }
                    : <String, dynamic>{},
              ),
            );
          },
        ),
      );
    final provider = AnimeWitcherNativeProvider(
      dio,
      SettingsRepository(MemoryStorageService()),
    );
    final episodes = await provider.getEpisodes(
      'https://animewitcher.com/watch/show',
    );
    expect(episodes.single.serverName, 'الحلقة ٢.٥');
    expect(episodes.single.toJson()['serverNumber'], '٢.٥');
  });

  test('raw source number JSON survives artwork copy and persistence without changing integer identity', () {
    for (final raw in ['٢', '٢.٥', '02.50']) {
      final original = Episode.fromJson({
        'name': '',
        'url': 'show|ep2',
        'episode': 2,
        'serverNumber': raw,
      });
      final saved = original.copyWith(posterUrl: 'artwork').toJson();
      expect(saved['serverNumber'], raw);
      expect(saved['episode'], 2);
      expect(Episode.fromJson(saved).toJson()['serverNumber'], raw);
    }
  });

  test('history retains the original generic name rather than synthesizing a different label', () {
    const original = 'الحلقة ٢';
    final saved = episodeTitleForStorage(episode: 2, title: original);
    expect(saved, original);
    expect(
      continueWatchingPrimaryLabel(episode: 2, episodeTitle: saved),
      original,
    );
  });

  test(
    'history retains decimal and special labels without filename normalization',
    () {
      for (final original in [
        'الحلقة ٢.٥',
        'الحلقة الخاصة: العودة / الجزء؟',
        '  الحلقة ٢  ',
      ]) {
        expect(episodeTitleForStorage(episode: 2, title: original), original);
        expect(
          continueWatchingPrimaryLabel(episode: 2, episodeServerName: original),
          original,
        );
      }
    },
  );

  testWidgets(
    'watching chooser fetches again after a successful list was cached',
    (tester) async {
      final provider = _Sources();
      final context = await _shell(tester, provider);
      final container = ProviderScope.containerOf(context);
      final prefetch = container.read(streamSourcePrefetchProvider);
      final cached = prefetch.sources(provider, _episode.url);
      provider.pending.single.complete(_list('cached'));
      await cached;
      final launcher = container.read(playbackLauncherProvider);
      final first = launcher.chooseSourceForItem(
        context,
        _item,
        _episode.url,
        episode: _episode,
      );
      await tester.pump();
      expect(provider.pending, hasLength(2));
      provider.pending.last.complete(_list('fresh-first'));
      await tester.pumpAndSettle();
      expect(find.text('fresh-first'), findsOneWidget);
      expect(find.text('cached'), findsNothing);
      Navigator.of(tester.element(find.text('fresh-first'))).pop();
      await tester.pumpAndSettle();
      expect(
        await pumpUntilFuture(tester, first, 'dismissed fresh chooser'),
        isNull,
      );
      final second = launcher.chooseSourceForItem(
        context,
        _item,
        _episode.url,
        episode: _episode,
      );
      await tester.pump();
      expect(provider.pending, hasLength(3));
      provider.pending.last.complete(_list('fresh-second'));
      await tester.pumpAndSettle();
      expect(find.text('fresh-second'), findsOneWidget);
      Navigator.of(tester.element(find.text('fresh-second'))).pop();
      await tester.pumpAndSettle();
      expect(
        await pumpUntilFuture(tester, second, 'dismissed second chooser'),
        isNull,
      );
    },
  );

  testWidgets(
    'older canceled chooser completion cannot replace a newer source list',
    (tester) async {
      final provider = _Sources();
      final context = await _shell(tester, provider);
      final launcher = ProviderScope.containerOf(context)
          .read(playbackLauncherProvider);
      final old = launcher.chooseSourceForItem(
        context,
        _item,
        _episode.url,
        episode: _episode,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      Navigator.of(context, rootNavigator: true).pop();
      await tester.pumpAndSettle();
      expect(
        await pumpUntilFuture(tester, old, 'dismissed old chooser'),
        isNull,
      );
      final current = launcher.chooseSourceForItem(
        context,
        _item,
        _episode.url,
        episode: _episode,
      );
      await tester.pump();
      expect(provider.pending, hasLength(2));
      provider.pending.last.complete(_list('current'));
      await tester.pumpAndSettle();
      provider.pending.first.complete(_list('stale'));
      await tester.pumpAndSettle();
      expect(find.text('current'), findsOneWidget);
      expect(find.text('stale'), findsNothing);
      Navigator.of(tester.element(find.text('current'))).pop();
      await tester.pumpAndSettle();
      expect(
        await pumpUntilFuture(tester, current, 'dismissed current chooser'),
        isNull,
      );
    },
  );

  testWidgets('local episode bypasses fresh watching source discovery', (
    tester,
  ) async {
    final provider = _Sources();
    final context = await _shell(tester, provider, local: true);
    final source = await ProviderScope.containerOf(context)
        .read(playbackLauncherProvider)
        .chooseSourceForItem(context, _item, _episode.url, episode: _episode);
    expect(source!.source, 'محلي');
    expect(provider.pending, isEmpty);
  });

  for (final cancel in [false, true]) {
    testWidgets(
      'manual download resolution closes only its loading dialog cancel=$cancel',
      (tester) async {
        final provider = _Sources()
          ..resolution = Completer<List<StreamResult>>();
        final notifications = NotificationService();
        addTearDown(() {
          notifications.clearToasts();
          notifications.dispose();
        });
        final context = await _shell(
          tester,
          provider,
          notifications: notifications,
        );
        final launcher = ProviderScope.containerOf(context)
            .read(downloadLauncherProvider);
        final launched = launcher.launch(context, _item, episode: _episode);
        await tester.pump();
        provider.pending.single.complete([
          StreamResult(
            url: 'https://example.test/opaque',
            source: 'manual',
            requiresResolution: true,
          ),
        ]);
        await tester.pumpAndSettle();
        await tester.tap(find.text('manual'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        if (cancel) {
          await tester.tap(find.text('إلغاء'));
          await tester.pumpAndSettle();
          provider.resolution!.complete(const []);
        } else {
          provider.resolution!.completeError(
            StateError('resolution unavailable'),
          );
        }
        await pumpUntilFuture(tester, launched, 'download launch completion');
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('episode page'), findsOneWidget);
        expect(notifications.toasts, hasLength(cancel ? 0 : 1));
        expect(tester.takeException(), isNull);
        notifications.clearToasts();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final scenario in <({String title, String url, String? filename})>[
    for (final title in <String>[
      'العنوان العربي',
      '日本語の映画',
      'Mix العربية 日本語',
      '',
      '...',
      List.filled(100, '🧙').join(),
    ])
      (title: title, url: 'https://cdn.test/stream/', filename: null),
    (
      title: 'Ignored title',
      url: 'https://cdn.test/fallback.mp4',
      filename: 'One  Piece; الحلقة 0100 1080p.mkv',
    ),
    (
      title: 'Ignored title',
      url: 'https://cdn.test/one%20piece%200100%201080p',
      filename: '',
    ),
  ]) {
    final title = scenario.title;

    testWidgets(
      'actual launch preserves server name or uses safe fallback title=$title filename=${scenario.filename}',
      (tester) async {
        final previous = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _Paths();
        addTearDown(() => PathProviderPlatform.instance = previous);
        final provider = _Sources();
        final storage = _CapturedDownload();
        final notifications = NotificationService();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          notifications.clearToasts();
          notifications.dispose();
        });
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 200,
                    headers: Headers.fromMap({
                      'content-length': ['4096'],
                      'content-type': ['video/mp4'],
                      if (scenario.filename?.isNotEmpty == true)
                        'content-disposition': [
                          'attachment; filename="${scenario.filename}"',
                        ],
                    }),
                    data: options.method == 'HEAD'
                        ? null
                        : ResponseBody.fromString('', 200),
                  ),
                );
              },
            ),
          );
        final context = await _shell(
          tester,
          provider,
          auto: true,
          notifications: notifications,
          storage: storage,
          dio: dio,
        );
        final launcher = ProviderScope.containerOf(context)
            .read(downloadLauncherProvider);
        final launched = launcher.launch(
          context,
          MultimediaItem(
            title: title,
            url: 'https://example.test/movie',
            posterUrl: '',
          ),
        );
        await tester.pump();
        provider.pending.single.complete([
          StreamResult(url: scenario.url, source: 'movie'),
        ]);
        await pumpUntil(
          tester,
          () => find.byType(ElevatedButton).evaluate().length == 1,
          'download confirmation',
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(ElevatedButton), findsOneWidget);
        await tester.tap(find.byType(ElevatedButton));
        await pumpUntilFuture(tester, launched, 'download launch completion');
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          storage.filePath,
          isNotNull,
          reason: notifications.toasts.map((toast) => toast.message).join('; '),
        );
        final filename = p.basename(storage.filePath!);
        final stem = p.basenameWithoutExtension(filename);
        if (scenario.filename == null) expect(p.extension(filename), '.mp4');
        expect(stem, isNotEmpty);
        expect(stem.startsWith('.'), isFalse);
        expect(utf8.encode(filename).length, lessThanOrEqualTo(255));
        final original = sanitizeDownloadFileName(title);
        if (scenario.filename == null) {
          expect(stem, original.isEmpty ? 'video' : original);
        } else {
          expect(
            filename,
            scenario.filename!.isEmpty
                ? 'one piece 0100 1080p'
                : scenario.filename,
          );
        }
        expect(
          storage.logicalId,
          logicalDownloadIdFor(
            animeId: 'https://example.test/movie',
            episodeKey: 'https://example.test/movie',
            variantKey: 'default',
          ).value,
        );
        expect(tester.takeException(), isNull);
        notifications.clearToasts();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final fails in [false, true]) {
    testWidgets(
      'auto download source failure keeps its caller route fails=$fails and permits retry',
      (tester) async {
        final provider = _Sources();
        final notifications = NotificationService();
        addTearDown(() {
          notifications.clearToasts();
          notifications.dispose();
        });
        final context = await _shell(
          tester,
          provider,
          auto: true,
          notifications: notifications,
        );
        final launcher = ProviderScope.containerOf(context)
            .read(downloadLauncherProvider);
        final first = launcher.launch(context, _item, episode: _episode);
        await tester.pump();
        if (fails) {
          provider.pending.single.completeError(
            StateError('source unavailable'),
          );
        } else {
          provider.pending.single.complete(const []);
        }
        await tester.pump();
        await pumpUntilFuture(tester, first, 'failed auto launch');
        expect(find.text('episode page'), findsOneWidget);
        expect(notifications.toasts, hasLength(1));
        final retry = launcher.launch(context, _item, episode: _episode);
        await tester.pump();
        expect(provider.pending, hasLength(2));
        provider.pending.last.complete(const []);
        await tester.pump();
        await pumpUntilFuture(tester, retry, 'failed auto retry');
        expect(find.text('episode page'), findsOneWidget);
        expect(notifications.toasts, hasLength(2));
        expect(tester.takeException(), isNull);
        notifications.clearToasts();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
