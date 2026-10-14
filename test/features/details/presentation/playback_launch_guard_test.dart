import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/providers/episode_sort_provider.dart';

import '../../../support/widget_completion.dart';

import 'package:animewitcher/core/services/notification_service.dart';
import 'package:animewitcher/features/details/presentation/downloaded_file_provider.dart';
import 'package:animewitcher/features/details/presentation/details_controller.dart';
import 'package:animewitcher/features/details/presentation/playback_launcher.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/download_progress_v2_provider.dart';
import 'package:animewitcher/features/library/presentation/widgets/downloads_tab.dart';
import 'package:animewitcher/features/library/presentation/widgets/completed_download_episode_card.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/loading_dialog.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:animewitcher/features/settings/presentation/player_settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Settings extends PlayerSettingsNotifier {
  _Settings(this.pending);
  final Future<PlayerSettings> pending;
  @override
  Future<PlayerSettings> build() => pending;
}

class _History extends WatchHistory {
  _History(this.pending);
  final Future<void> pending;
  int calls = 0;
  @override
  List<HistoryItem> build() => const [];
  @override
  Future<void> recordOpened(
    MultimediaItem item, {
    String? lastEpisodeUrl,
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodeServerName,
    String? episodeServerNumber,
    String? episodePosterUrl,
  }) {
    calls++;
    return pending;
  }
}

class _Files extends DownloadedFiles {
  _Files(this.pending, {this.requireEpisode = false});
  final bool requireEpisode;
  int sourceLookups = 0;
  final Future<File?> pending;
  int calls = 0;
  @override
  Map<String, File?> build() => const {};
  @override
  Future<File?> resolveFile(
    MultimediaItem item, {
    Episode? episode,
    String? logicalId,
  }) {
    calls++;
    if (requireEpisode && episode == null) return Future.value(null);
    return pending;
  }

  @override
  Future<File?> resolveFileForTrackingUrl(
    String trackingUrl, {
    required MultimediaItem item,
    Episode? episode,
  }) {
    return resolveFile(item, episode: episode);
  }
}

class _PlayerPushes extends NavigatorObserver {
  int count = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.settings.name == 'player') count++;
  }
}

final _item = MultimediaItem(
  title: 'Saved show',
  url: 'show://saved',
  posterUrl: '',
);
Episode _episode(int number) =>
    Episode(name: 'Saved episode', url: 'episode://$number', episode: number);

class _Notifications extends NotificationService {
  int errors = 0;
  @override
  void showError(
    String message, {
    String? title,
    IconData? icon,
    Duration duration = NotificationService.defaultDuration,
  }) {
    errors++;
  }
}

class _Downloads extends DownloadsNotifier {
  _Downloads(this.rows);
  final List<DownloadItem> rows;
  @override
  Future<List<DownloadItem>> build() async => rows;
}

class _Sort extends EpisodeSortAscendingNotifier {
  @override
  bool build() => true;
}

class _GeneralSettings extends GeneralSettingsNotifier {
  _GeneralSettings(this.auto);
  final bool auto;
  @override
  GeneralSettings build() => GeneralSettings(autoSelectStreamSource: auto);
}

class _Details extends DetailsController {
  @override
  DetailsState build(String itemUrl) => DetailsState(details: AsyncData(_item));
}

class _Extensions extends ExtensionManager {
  _Extensions(this.provider);
  final AnimeWitcherProvider provider;
  @override
  List<AnimeWitcherProvider> build() => [provider];
}

class _Provider extends AnimeWitcherProvider {
  final sources = Completer<List<StreamResult>>();
  final catalog = Completer<List<Episode>>();
  @override
  String get packageName => 'test.playback';
  @override
  String get name => 'Playback test';
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
  Future<MultimediaItem> getDetails(String url) async => _item;
  @override
  Future<List<Episode>> getEpisodes(String url) => catalog.future;
  @override
  Future<List<StreamResult>> loadStreamSources(String url) => sources.future;
  @override
  Future<List<StreamResult>> loadStreams(String url) async => const [];
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

class _Harness {
  _Harness({
    Future<PlayerSettings>? settings,
    Future<void>? history,
    Future<File?>? file,
    Widget? home,
    List<DownloadItem>? rows,
    bool requireEpisode = false,
    _Provider? provider,
    bool auto = true,
  }) {
    files = _Files(
      file ?? Future.value(File('/tmp/saved.mp4')),
      requireEpisode: requireEpisode,
    );
    watchHistory = _History(history ?? Future.value());
    container = ProviderContainer(
      overrides: [
        playerSettingsProvider.overrideWith(
          () => _Settings(settings ?? Future.value(const PlayerSettings())),
        ),
        watchHistoryProvider.overrideWith(() => watchHistory),
        notificationServiceProvider.overrideWith((ref) {
          ref.onDispose(notifications.clearToasts);
          return notifications;
        }),
        downloadedFilesProvider.overrideWith(() => files),
        detailsControllerProvider(_item.url).overrideWith(_Details.new),
        if (rows != null)
          downloadsProvider.overrideWith(() => _Downloads(rows)),
        if (rows != null) downloadProgressProvider.overrideWithValue(const {}),
        if (rows != null) episodeSortAscendingProvider.overrideWith(_Sort.new),
        if (provider != null) ...[
          activeProviderProvider.overrideWithValue(provider),
          extensionManagerProvider.overrideWith(() => _Extensions(provider)),
          generalSettingsProvider.overrideWith(() => _GeneralSettings(auto)),
        ],
      ],
    );
    router = GoRouter(
      observers: [pushes],
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) {
            origin = context;
            return Scaffold(body: home ?? const Text('Saved downloads'));
          },
        ),
        GoRoute(
          path: '/player',
          name: 'player',
          builder: (context, state) {
            opened = state.extra! as PlayerRouteExtra;
            return const Scaffold(body: Text('Saved player'));
          },
        ),
        GoRoute(
          path: '/other',
          builder: (context, state) => const Scaffold(body: Text('Other page')),
        ),
      ],
    );
  }
  late final ProviderContainer container;
  late final GoRouter router;
  late final _Files files;
  late final _History watchHistory;
  final pushes = _PlayerPushes();
  final notifications = _Notifications();
  late BuildContext origin;
  PlayerRouteExtra? opened;

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> play(int episode, {bool direct = true}) => container
      .read(playbackLauncherProvider)
      .play(
        origin,
        direct ? '/tmp/saved$episode.mp4' : _episode(episode).url,
        baseItem: _item,
        episode: _episode(episode),
      );

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    container.dispose();
  }
}

void main() {
  testWidgets(
    'repeated episode launches while settings wait open one player and unlock on pop',
    (tester) async {
      final settings = Completer<PlayerSettings>();
      final app = _Harness(settings: settings.future);
      await app.mount(tester);
      final requests = [
        for (var episode = 1; episode <= 12; episode++) app.play(episode),
      ];
      await tester.pump();
      expect(app.pushes.count, 0);
      settings.complete(const PlayerSettings());
      await tester.pumpAndSettle();
      expect(app.pushes.count, 1);
      expect(app.opened?.episode?.episode, 1);
      app.router.pop();
      await tester.pumpAndSettle();
      await Future.wait(requests);
      final next = app.play(2);
      await tester.pumpAndSettle();
      expect(app.pushes.count, 2);
      app.router.pop();
      await tester.pumpAndSettle();
      await next;
      await app.dispose(tester);
    },
  );

  testWidgets(
    'stalled downloaded-file resolution is single-flight across episode taps',
    (tester) async {
      final file = Completer<File?>();
      final app = _Harness(file: file.future);
      await app.mount(tester);
      final requests = [
        for (var episode = 1; episode <= 12; episode++)
          app.play(episode, direct: false),
      ];
      await tester.pump();
      expect(app.files.calls, 1);
      file.complete(File('/tmp/saved.mp4'));
      await tester.pumpAndSettle();
      expect(app.pushes.count, 1);
      app.router.pop();
      await tester.pumpAndSettle();
      await Future.wait(requests);
      await app.dispose(tester);
    },
  );

  testWidgets(
    'local player opens while optional history recording remains stalled',
    (tester) async {
      final history = Completer<void>();
      final app = _Harness(history: history.future);
      await app.mount(tester);
      final request = app.play(1);
      await tester.pumpAndSettle();
      expect(app.pushes.count, 1);
      expect(app.watchHistory.calls, 1);
      history.complete();
      await tester.pumpAndSettle();
      app.router.pop();
      await tester.pumpAndSettle();
      await request;
      await app.dispose(tester);
    },
  );

  testWidgets(
    'pending launch is dropped when another route covers its origin',
    (tester) async {
      final settings = Completer<PlayerSettings>();
      final app = _Harness(settings: settings.future);
      await app.mount(tester);
      final request = app.play(1);
      unawaited(app.router.push('/other'));
      await tester.pumpAndSettle();
      settings.complete(const PlayerSettings());
      await tester.pumpAndSettle();
      expect(app.pushes.count, 0);
      expect(find.text('Other page'), findsOneWidget);
      app.router.pop();
      await tester.pumpAndSettle();
      await request;
      await app.dispose(tester);
    },
  );
  testWidgets(
    'timed-out local preflight unlocks and cannot push on later completion',
    (tester) async {
      final file = Completer<File?>();
      final app = _Harness(file: file.future);
      await app.mount(tester);
      var completed = false;
      final first = app.play(1, direct: false).then((_) => completed = true);
      await tester.pump();
      await tester.pump(const Duration(seconds: 11));
      expect(completed, isTrue);
      expect(app.notifications.errors, 1);
      expect(app.pushes.count, 0);
      final second = app.play(2);
      await tester.pumpAndSettle();
      expect(app.pushes.count, 1);
      file.complete(File('/tmp/late.mp4'));
      await tester.pumpAndSettle();
      expect(app.pushes.count, 1);
      app.router.pop();
      await tester.pumpAndSettle();
      await Future.wait([first, second]);
      await app.dispose(tester);
    },
  );
  testWidgets(
    'completed download taps share guard before file preflight starts',
    (tester) async {
      final file = Completer<File?>();
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('aw-launch-ui-'),
      ))!;
      final originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      await tester.runAsync(
        () => DefaultCacheManager().getFileFromCache('playback-guard-cache'),
      );
      addTearDown(() async {
        PathProviderPlatform.instance = originalPaths;
        await root.delete(recursive: true);
      });
      final rows = [
        for (var episode = 1; episode <= 2; episode++)
          DownloadItem(
            task: DownloadTask(
              taskId: 'saved-$episode',
              url: 'https://cdn.test/$episode.mp4',
            ),
            status: TaskStatus.complete,
            progress: 1,
            item: _item,
            episode: _episode(episode),
            timestamp: episode,
          ),
      ];
      final app = _Harness(
        file: file.future,
        rows: rows,
        home: const DownloadsTab(),
      );
      await app.mount(tester);
      await tester.tap(find.text('المكتملة'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Saved show'));
      await tester.pumpAndSettle();
      final cards = tester
          .widgetList<CompletedDownloadEpisodeCard>(
            find.byType(CompletedDownloadEpisodeCard),
          )
          .toList();
      expect(cards, hasLength(2));
      for (final widget
          in tester
              .widgetList<FutureBuilder<File?>>(
                find.byWidgetPredicate(
                  (widget) => widget is FutureBuilder<File?>,
                ),
              )
              .toList()) {
        if (widget.future != null) {
          await pumpUntilFuture(tester, widget.future!, 'saved artwork lookup');
        }
      }
      for (var tap = 0; tap < 12; tap++) {
        cards[tap % 2].onPlay();
      }
      await tester.pump();
      expect(app.files.calls, 1);
      file.complete(File('/tmp/saved.mp4'));
      await tester.pumpAndSettle();
      expect(app.pushes.count, 1);
      app.router.pop();
      await tester.pumpAndSettle();
      await app.dispose(tester);
    },
  );

  testWidgets(
    'known downloaded episode keeps its identity when details catalog is absent',
    (tester) async {
      final provider = _Provider();
      final app = _Harness(requireEpisode: true, provider: provider);
      await app.mount(tester);
      final request = app.container
          .read(detailsControllerProvider(_item.url).notifier)
          .handlePlayPress(app.origin, _item, specificEpisode: _episode(2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(app.pushes.count, 1);
      expect(app.opened?.episode?.episode, 2);
      app.router.pop();
      await tester.pumpAndSettle();
      await request;
      await app.dispose(tester);
    },
  );

  testWidgets(
    'online automatic picker can wait longer than local preflight and restore origin',
    (tester) async {
      final provider = _Provider();
      final app = _Harness(provider: provider, file: Future.value(null));
      await app.mount(tester);
      final request = app.play(1, direct: false);
      await pumpUntil(
        tester,
        () => find.byType(LoadingDialog).evaluate().isNotEmpty,
        'automatic source loading',
      );
      expect(find.byType(LoadingDialog), findsOneWidget);
      await tester.pump(const Duration(seconds: 11));
      provider.sources.complete(const [
        StreamResult(
          url: 'https://cdn.test/video.mp4',
          source: 'PD',
          quality: '1080',
        ),
      ]);
      await tester.pumpAndSettle();
      expect(app.pushes.count, 1);
      app.router.pop();
      await tester.pumpAndSettle();
      await request;
      await app.dispose(tester);
    },
  );

  testWidgets(
    'timed-out explicit download resolver never removes a later missing result',
    (tester) async {
      final file = Completer<String?>();
      final app = _Harness();
      await app.mount(tester);
      var removals = 0;
      final request = app.container
          .read(playbackLauncherProvider)
          .play(
            app.origin,
            'episode://1',
            baseItem: _item,
            episode: _episode(1),
            resolveUrl: () => file.future,
            onMissingFile: () async {
              removals++;
            },
          );
      await tester.pump();
      await tester.pump(const Duration(seconds: 11));
      await request;
      expect(removals, 0);
      file.complete(null);
      await tester.pumpAndSettle();
      expect(removals, 0);
      expect(app.pushes.count, 0);
      await app.dispose(tester);
    },
  );
  testWidgets(
    'manual source picker selection restores current origin before push',
    (tester) async {
      final provider = _Provider();
      provider.sources.complete(const [
        StreamResult(
          url: 'https://cdn.test/video.mp4',
          source: 'PD',
          quality: '1080',
        ),
      ]);
      final app = _Harness(
        provider: provider,
        file: Future.value(null),
        auto: false,
      );
      await app.mount(tester);
      final request = app.play(1, direct: false);
      await pumpUntil(
        tester,
        () => find.text('PD').evaluate().isNotEmpty,
        'manual source row',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('PD'));
      await tester.pumpAndSettle();
      expect(app.pushes.count, 1);
      expect(app.opened?.selectedSource?.source, 'PD');
      app.router.pop();
      await tester.pumpAndSettle();
      await request;
      await app.dispose(tester);
    },
  );

  testWidgets(
    'cancelled source picker releases guard for a later local launch',
    (tester) async {
      final provider = _Provider();
      provider.sources.complete(const [
        StreamResult(url: 'https://cdn.test/video.mp4', source: 'PD'),
      ]);
      final app = _Harness(
        provider: provider,
        file: Future.value(null),
        auto: false,
      );
      await app.mount(tester);
      final first = app.play(1, direct: false);
      await pumpUntil(
        tester,
        () => find.text('PD').evaluate().isNotEmpty,
        'manual source row',
      );
      Navigator.of(app.origin, rootNavigator: true).pop();
      await tester.pumpAndSettle();
      await first;
      expect(app.pushes.count, 0);
      final second = app.play(2);
      await tester.pumpAndSettle();
      expect(app.pushes.count, 1);
      app.router.pop();
      await tester.pumpAndSettle();
      await second;
      await app.dispose(tester);
    },
  );

  testWidgets('failed local preflight releases guard after error', (
    tester,
  ) async {
    final file = Completer<File?>();
    final app = _Harness(file: file.future);
    await app.mount(tester);
    Object? failure;
    final first = app.play(1, direct: false).catchError((Object error) {
      failure = error;
    });
    await tester.pump();
    file.completeError(StateError('local read failed'));
    await tester.pump();
    await first;
    expect(failure, isA<StateError>());
    final second = app.play(2);
    await tester.pumpAndSettle();
    expect(app.pushes.count, 1);
    app.router.pop();
    await tester.pumpAndSettle();
    await second;
    await app.dispose(tester);
  });

  testWidgets(
    'external player fallback retains guard until internal route closes',
    (tester) async {
      final app = _Harness(
        settings: Future.value(
          const PlayerSettings(preferredPlayer: 'unknown-player'),
        ),
      );
      await app.mount(tester);
      final first = app.play(1);
      await tester.pumpAndSettle();
      expect(app.pushes.count, 1);
      await app.play(2);
      expect(app.pushes.count, 1);
      app.router.pop();
      await tester.pumpAndSettle();
      await first;
      final second = app.play(2);
      await tester.pumpAndSettle();
      expect(app.pushes.count, 2);
      app.router.pop();
      await tester.pumpAndSettle();
      await second;
      await app.dispose(tester);
    },
  );
  testWidgets(
    'downloaded Continue Watching locks before tracking-url resolution',
    (tester) async {
      final file = Completer<File?>();
      final app = _Harness(file: file.future);
      await app.mount(tester);
      final history = HistoryItem(
        item: _item,
        timestamp: 1,
        position: 0,
        duration: 100,
        lastEpisodeUrl: 'episode://2',
        episode: 2,
        season: 1,
      );
      final requests = [
        for (var tap = 0; tap < 12; tap++)
          app.container
              .read(playbackLauncherProvider)
              .playFromContinueWatching(app.origin, history),
      ];
      await tester.pump();
      expect(app.files.calls, 1);
      file.complete(File('/tmp/saved.mp4'));
      await tester.pumpAndSettle();
      expect(app.pushes.count, 1);
      expect(app.opened?.progressUrl, 'episode://2');
      app.router.pop();
      await tester.pumpAndSettle();
      await Future.wait(requests);
      await app.dispose(tester);
    },
  );
}
