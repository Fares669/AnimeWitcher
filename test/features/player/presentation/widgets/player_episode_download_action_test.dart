import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/providers/episode_sort_provider.dart';
import 'package:animewitcher/core/services/notification_service.dart';
import 'package:animewitcher/core/storage/episode_watch_repository.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/core/utils/download_progress_data.dart';
import 'package:animewitcher/features/details/presentation/details_controller.dart';
import 'package:animewitcher/features/details/presentation/download_launcher.dart';
import 'package:animewitcher/features/details/presentation/downloaded_file_provider.dart';
import 'package:animewitcher/features/details/presentation/widgets/download_management_dialog.dart';
import 'package:animewitcher/features/details/presentation/widgets/download_progress_dialog.dart';
import 'package:animewitcher/features/details/presentation/widgets/episode_action_chip.dart';
import 'package:animewitcher/features/library/presentation/download_progress_v2_provider.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/player/presentation/player_controller.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_side_panel.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _episode = Episode(
  name: 'Episode nine',
  url: 'https://animewitcher.test/show/9',
  episode: 9,
);
final _show = MultimediaItem(
  title: 'Saved show',
  url: 'https://animewitcher.test/show',
  posterUrl: '',
  contentType: MultimediaContentType.anime,
  episodes: [_episode],
);
MultimediaItem _riftShow({List<Episode>? episodes}) => MultimediaItem(
  title: 'Rift show',
  url: _show.url,
  posterUrl: '',
  provider: 'com.animerift.provider',
  contentType: MultimediaContentType.anime,
  episodes: episodes ?? [_episode],
);
final _savedFile = File('/saved/episode-nine.mp4');

DownloadItem _download({
  TaskStatus status = TaskStatus.complete,
  MultimediaItem? item,
  Episode? episode,
  String taskId = 'episode-nine-task',
  String? logicalId = 'episode-nine-logical',
  double? progress,
}) => DownloadItem(
  task: DownloadTask(
    taskId: taskId,
    url: 'https://cdn.test/9.mp4',
    filename: '9.mp4',
  ),
  item: item ?? _show,
  episode: episode ?? _episode,
  logicalId: logicalId,
  trackingUrl: (episode ?? _episode).url,
  destinationPath: _savedFile.path,
  status: status,
  progress: progress ?? (status == TaskStatus.complete ? 1 : 0.4),
  timestamp: 1,
);

class _Downloads extends DownloadsNotifier {
  _Downloads(this.items, {this.error});
  final List<DownloadItem> items;
  final Object? error;
  final removed = <DownloadItem>[];
  final pausedTaskIds = <String>[];

  @override
  Future<List<DownloadItem>> build() async => items;

  @override
  Future<void> removeDownload(DownloadItem item) async {
    if (error != null) throw error!;
    removed.add(item);
    state = AsyncData(
      state.requireValue.where((d) => d.id != item.id).toList(),
    );
  }

  @override
  Future<void> pauseDownload(String taskId) async {
    pausedTaskIds.add(taskId);
  }
}

class _Files extends DownloadedFiles {
  _Files(this.cached, {this.cacheOnly = false});
  final bool cached;
  final bool cacheOnly;
  Object? checkError;
  Completer<void>? pendingCheck;
  final checkedItems = <MultimediaItem>[];

  @override
  Map<String, File?> build() => {
    downloadedFileKey(_show, episode: _episode): cached ? _savedFile : null,
  };

  @override
  Future<void> checkFile(MultimediaItem item, {Episode? episode}) async {
    checkedItems.add(item);
    await pendingCheck?.future;
    if (checkError != null) throw checkError!;
    final completed = completedEpisodeDownload(
      ref.read(downloadsProvider).value ?? [],
      item,
      episode!,
    );
    state = {
      ...state,
      downloadedFileKey(item, episode: episode):
          cached && (completed != null || cacheOnly) ? _savedFile : null,
    };
  }
}

class _Player extends PlayerController {
  @override
  PlayerState build() => PlayerState(activeEpisodeUrl: _episode.url);
}

class _Details extends DetailsController {
  @override
  DetailsState build(String itemUrl) => DetailsState(item: _show);
}

class _RiftDetails extends DetailsController {
  @override
  DetailsState build(String itemUrl) => const DetailsState(isAscending: false);
}

class _TestEpisodeSort extends EpisodeSortAscendingNotifier {
  @override
  bool build() => true;

  @override
  void setAscending(bool value) => state = value;
}

class _History extends Fake implements HistoryRepository {
  @override
  int positionForItem(
    MultimediaItem item, {
    String? episodeUrl,
    int? season,
    int? episode,
  }) => 0;

  @override
  int durationForItem(
    MultimediaItem item, {
    String? episodeUrl,
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

  @override
  int getEpisodeDuration(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;
}

class _Watch extends Fake implements EpisodeWatchRepository {
  @override
  bool isWatched(String mainUrl, Episode episode) => false;

  @override
  bool isWatchedFor(MultimediaItem item, Episode episode) => false;
}

class _Launcher extends DownloadLauncher {
  _Launcher(super.ref);
  final launched = <String>[];
  final sourceItems = <MultimediaItem>[];

  @override
  Future<void> launch(
    BuildContext context,
    MultimediaItem item, {
    String? episodeUrl,
    Episode? episode,
  }) async {
    launched.add(episodeUrl!);
    sourceItems.add(item);
  }
}

Future<ProviderContainer> _pumpPanel(
  WidgetTester tester, {
  required _Downloads downloads,
  bool cached = true,
  _Files? files,
  NotificationService? notifications,
  MultimediaItem? item,
  bool includeRiftDetails = false,
  Map<String, DownloadProgressData>? progress,
  ValueNotifier<MultimediaItem>? selectedItem,
}) async {
  final container = ProviderContainer(
    overrides: [
      downloadsProvider.overrideWith(() => downloads),
      downloadedFilesProvider.overrideWith(() => files ?? _Files(cached)),
      playerControllerProvider.overrideWith(_Player.new),
      detailsControllerProvider(_show.url).overrideWith(_Details.new),
      if (item != null &&
          detailsControllerKey(item) != _show.url &&
          !includeRiftDetails)
        detailsControllerProvider(detailsControllerKey(item))
            .overrideWith(_Details.new),
      if (includeRiftDetails)
        detailsControllerProvider(detailsControllerKey(item!))
            .overrideWith(_RiftDetails.new),
      if (includeRiftDetails)
        episodeSortAscendingProvider.overrideWith(_TestEpisodeSort.new),
      historyRepositoryProvider.overrideWithValue(_History()),
      episodeWatchRepositoryProvider.overrideWithValue(_Watch()),
      downloadLauncherProvider.overrideWith((ref) => _Launcher(ref)),
      downloadProgressProvider.overrideWithValue(
        progress ??
            {
              if (downloads.items.isNotEmpty)
                'episode-nine-logical': DownloadProgressData(
                  taskId: downloads.items.single.id,
                  progress: 0.4,
                  status: downloads.items.single.status,
                ),
            },
      ),
      if (notifications != null)
        notificationServiceProvider.overrideWithValue(notifications),
    ],
  );
  addTearDown(container.dispose);
  await container.read(downloadsProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: 430,
              child: selectedItem == null
                  ? PlayerEpisodesPanel(item: item ?? _show, onClose: () {})
                  : ValueListenableBuilder<MultimediaItem>(
                      valueListenable: selectedItem,
                      builder: (context, selected, _) =>
                          PlayerEpisodesPanel(item: selected, onClose: () {}),
                    ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  testWidgets('episode picker uses the original provider details state', (
    tester,
  ) async {
    final rift = _riftShow(
      episodes: [
        Episode(name: 'Rift first', url: 'rift/1', episode: 1),
        Episode(name: 'Rift second', url: 'rift/2', episode: 2),
        Episode(name: 'Rift third', url: 'rift/3', episode: 3),
      ],
    );
    final container = await _pumpPanel(
      tester,
      item: rift,
      downloads: _Downloads([]),
      cached: false,
      includeRiftDetails: true,
    );

    double rowY(String title) => tester.getTopLeft(find.text(title)).dy;

    expect(
      container.read(detailsControllerProvider(_show.url)).isAscending,
      true,
    );
    expect(
      container
          .read(detailsControllerProvider(detailsControllerKey(rift)))
          .isAscending,
      false,
    );
    expect(rowY('Rift third'), lessThan(rowY('Rift first')));

    // Changing the other provider's details state must not reorder Rift rows.
    container.read(detailsControllerProvider(_show.url).notifier).toggleSort();
    await tester.pump();
    expect(rowY('Rift third'), lessThan(rowY('Rift first')));

    container
        .read(detailsControllerProvider(detailsControllerKey(rift)).notifier)
        .toggleSort();
    await tester.pump();
    expect(rowY('Rift first'), lessThan(rowY('Rift third')));
  });

  testWidgets('identical episode URLs do not route native downloads to Rift', (
    tester,
  ) async {
    final rift = _riftShow();
    final nativeDownload = _download(status: TaskStatus.running);
    final container = await _pumpPanel(
      tester,
      item: rift,
      downloads: _Downloads([nativeDownload]),
      cached: false,
      includeRiftDetails: true,
    );

    expect(find.byIcon(Icons.save_alt_rounded), findsOneWidget);
    expect(find.text('40%'), findsNothing);
    await tester.tap(find.byIcon(Icons.save_alt_rounded));
    await tester.pump();

    final launcher = container.read(downloadLauncherProvider) as _Launcher;
    expect(launcher.launched, [_episode.url]);
    expect(launcher.sourceItems.single, same(rift));
    expect(find.byType(DownloadProgressDialog), findsNothing);
  });

  testWidgets('player binds progress and actions to the Rift task', (
    tester,
  ) async {
    final rift = _riftShow();
    final native = _download(status: TaskStatus.running);
    final riftTask = _download(
      item: rift,
      status: TaskStatus.running,
      logicalId: 'rift-logical',
      taskId: 'rift-task',
      progress: 0.7,
    );
    await _pumpPanel(
      tester,
      item: rift,
      downloads: _Downloads([native, riftTask]),
      cached: false,
      includeRiftDetails: true,
      progress: {
        'episode-nine-logical': DownloadProgressData(
          taskId: native.id,
          progress: 0.4,
          status: native.status,
        ),
        'rift-logical': DownloadProgressData(
          taskId: riftTask.id,
          progress: 0.7,
          status: riftTask.status,
        ),
      },
    );

    expect(find.text('70%'), findsOneWidget);
    expect(find.text('40%'), findsNothing);
    await tester.tap(find.byType(EpisodeActionChip));
    await tester.pump();
    expect(
      tester
          .widget<DownloadProgressDialog>(find.byType(DownloadProgressDialog))
          .trackingUrl,
      'rift-logical',
    );
  });

  testWidgets(
    'queued Rift download opens by logical ID before first progress snapshot',
    (tester) async {
      final rift = _riftShow();
      final native = _download(status: TaskStatus.running);
      final queued = _download(
        item: rift,
        status: TaskStatus.enqueued,
        taskId: 'rift-queued-task',
        logicalId: 'rift-queued-logical',
        progress: 0,
      );
      final downloads = _Downloads([native, queued]);
      await _pumpPanel(
        tester,
        item: rift,
        downloads: downloads,
        cached: false,
        includeRiftDetails: true,
        progress: {
          _episode.url: DownloadProgressData(
            taskId: native.id,
            progress: 0.4,
            status: native.status,
          ),
        },
      );

      expect(find.text('0%'), findsOneWidget);
      await tester.tap(find.byType(EpisodeActionChip));
      await tester.pump();

      expect(find.byType(DownloadProgressDialog), findsOneWidget);
      expect(
        tester
            .widget<DownloadProgressDialog>(find.byType(DownloadProgressDialog))
            .trackingUrl,
        'rift-queued-logical',
      );
      expect(find.text('40%'), findsNothing);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(DownloadProgressDialog), findsOneWidget);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(DownloadProgressDialog)),
      )!;
      await tester.tap(find.text(l10n.pause));
      await tester.pump();
      expect(downloads.pausedTaskIds, ['rift-queued-task']);
    },
  );

  testWidgets('legacy tracking aliases cannot control another provider task', (
    tester,
  ) async {
    final rift = _riftShow();
    final native = _download(status: TaskStatus.running);
    final riftTask = _download(
      item: rift,
      status: TaskStatus.running,
      logicalId: null,
      taskId: 'rift-legacy-task',
      progress: 0.65,
    );
    await _pumpPanel(
      tester,
      item: rift,
      downloads: _Downloads([native, riftTask]),
      cached: false,
      includeRiftDetails: true,
      progress: {
        _episode.url: DownloadProgressData(
          taskId: native.id,
          progress: 0.4,
          status: native.status,
        ),
      },
    );

    expect(find.text('65%'), findsOneWidget);
    expect(find.text('40%'), findsNothing);
    await tester.tap(find.byType(EpisodeActionChip));
    await tester.pump();
    expect(find.byType(DownloadProgressDialog), findsNothing);
  });

  testWidgets('unambiguous legacy URL alias opens only for its matching task', (
    tester,
  ) async {
    final rift = _riftShow();
    final active = _download(
      item: rift,
      status: TaskStatus.running,
      logicalId: null,
      taskId: 'rift-legacy-only-task',
      progress: 0.65,
    );
    await _pumpPanel(
      tester,
      item: rift,
      downloads: _Downloads([active]),
      cached: false,
      includeRiftDetails: true,
      progress: {
        _episode.url: DownloadProgressData(
          taskId: active.id,
          progress: 0.65,
          status: active.status,
        ),
      },
    );

    expect(find.text('65%'), findsOneWidget);
    await tester.tap(find.byType(EpisodeActionChip));
    await tester.pump();
    expect(
      tester
          .widget<DownloadProgressDialog>(find.byType(DownloadProgressDialog))
          .trackingUrl,
      _episode.url,
    );
  });

  testWidgets(
    'shared legacy URL cannot use progress from another provider even with same task ID',
    (tester) async {
      final rift = _riftShow();
      final native = _download(
        status: TaskStatus.running,
        taskId: 'legacy-shared-id',
      );
      final riftTask = _download(
        item: rift,
        status: TaskStatus.running,
        logicalId: null,
        taskId: 'legacy-shared-id',
        progress: 0.65,
      );
      await _pumpPanel(
        tester,
        item: rift,
        downloads: _Downloads([native, riftTask]),
        cached: false,
        includeRiftDetails: true,
        progress: {
          _episode.url: DownloadProgressData(
            taskId: native.id,
            progress: 0.4,
            status: native.status,
          ),
        },
      );

      expect(find.text('65%'), findsOneWidget);
      expect(find.text('40%'), findsNothing);
      await tester.tap(find.byType(EpisodeActionChip));
      await tester.pump();
      expect(find.byType(DownloadProgressDialog), findsNothing);
    },
  );

  testWidgets(
    'stale logical progress opens controls for the active task only',
    (tester) async {
      final rift = _riftShow();
      final riftTask = _download(
        item: rift,
        status: TaskStatus.running,
        logicalId: 'rift-logical',
        taskId: 'rift-current-task',
        progress: 0.65,
      );
      final downloads = _Downloads([riftTask]);
      await _pumpPanel(
        tester,
        item: rift,
        downloads: downloads,
        cached: false,
        includeRiftDetails: true,
        progress: {
          'rift-logical': const DownloadProgressData(
            taskId: 'old-unrelated-task',
            progress: 0.4,
            status: TaskStatus.running,
          ),
        },
      );

      expect(find.text('65%'), findsOneWidget);
      expect(find.text('40%'), findsNothing);
      await tester.tap(find.byType(EpisodeActionChip));
      await tester.pump();
      expect(find.byType(DownloadProgressDialog), findsOneWidget);
      expect(
        tester
            .widget<DownloadProgressDialog>(find.byType(DownloadProgressDialog))
            .trackingUrl,
        'rift-logical',
      );
      expect(find.text('65%'), findsWidgets);
      expect(find.text('40%'), findsNothing);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(DownloadProgressDialog)),
      )!;
      await tester.tap(find.text(l10n.pause));
      await tester.pump();
      expect(downloads.pausedTaskIds, ['rift-current-task']);
    },
  );

  testWidgets('episode URLs shared within one provider respect the show', (
    tester,
  ) async {
    final otherShow = MultimediaItem(
      title: 'Another anime',
      url: '${_show.url}/other',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
      episodes: [_episode],
    );
    final container = await _pumpPanel(
      tester,
      item: otherShow,
      downloads: _Downloads([_download(status: TaskStatus.running)]),
      cached: false,
    );

    expect(find.byIcon(Icons.save_alt_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.save_alt_rounded));
    await tester.pump();
    expect(
      (container.read(
        downloadLauncherProvider,
      ) as _Launcher).sourceItems.single,
      same(otherShow),
    );
  });

  testWidgets('completed Rift task deletion preserves same-URL native task', (
    tester,
  ) async {
    final rift = _riftShow();
    final native = _download();
    final riftTask = _download(
      item: rift,
      taskId: 'rift-completed-task',
      logicalId: 'rift-completed-logical',
    );
    final downloads = _Downloads([native, riftTask]);
    final container = await _pumpPanel(
      tester,
      item: rift,
      downloads: downloads,
      cached: false,
      includeRiftDetails: true,
      progress: {},
    );

    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(AlertDialog)))!;
    await tester.tap(find.widgetWithText(FilledButton, l10n.delete));
    await tester.pumpAndSettle();

    expect(downloads.removed, [same(riftTask)]);
    expect(container.read(downloadsProvider).requireValue, [same(native)]);
    expect(find.byIcon(Icons.save_alt_rounded), findsOneWidget);
  });

  testWidgets('changing providers with identical URLs refreshes file lookup', (
    tester,
  ) async {
    final rift = _riftShow();
    final selection = ValueNotifier<MultimediaItem>(_show);
    addTearDown(selection.dispose);
    final files = _Files(true);
    await _pumpPanel(
      tester,
      item: rift,
      selectedItem: selection,
      downloads: _Downloads([_download()]),
      files: files,
      includeRiftDetails: true,
    );
    expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);

    selection.value = rift;
    await tester.pump();
    await tester.pump();

    expect(files.checkedItems.last, same(rift));
    expect(find.byIcon(Icons.save_alt_rounded), findsOneWidget);
  });

  for (final cached in [true, false]) {
    testWidgets('completed episode shows delete with cached file $cached', (
      tester,
    ) async {
      await _pumpPanel(
        tester,
        downloads: _Downloads([_download()]),
        cached: cached,
      );

      final action = tester.widget<EpisodeActionChip>(
        find.byType(EpisodeActionChip),
      );
      expect(action.icon, Icons.delete_outline_rounded);
      expect(
        action.color,
        Theme.of(tester.element(find.byType(EpisodeActionChip)))
            .colorScheme
            .error,
      );
      expect(action.tooltip, 'حذف الحلقة');
      expect(find.byIcon(Icons.download_done_rounded), findsNothing);
    });
  }

  testWidgets('delete asks the shared confirmation and cancel preserves it', (
    tester,
  ) async {
    final downloads = _Downloads([_download()]);
    final container = await _pumpPanel(tester, downloads: downloads);

    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(AlertDialog)))!;
    expect(find.text(l10n.confirmDeleteDownload), findsOneWidget);
    expect(find.byType(DownloadManagementDialog), findsNothing);
    expect(downloads.removed, isEmpty);

    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();
    expect(container.read(downloadsProvider).requireValue, hasLength(1));
    expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('rapid trash activations open only one confirmation', (
    tester,
  ) async {
    await _pumpPanel(tester, downloads: _Downloads([_download()]));

    final action = tester.widget<EpisodeActionChip>(
      find.byType(EpisodeActionChip),
    );
    action.onPressed();
    action.onPressed();
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog, skipOffstage: false), findsOneWidget);
  });

  testWidgets(
    'confirmed delete uses the Downloads action and refreshes the row',
    (tester) async {
      final completed = _download();
      final downloads = _Downloads([completed]);
      final container = await _pumpPanel(tester, downloads: downloads);

      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(AlertDialog)),
      )!;
      await tester.tap(find.widgetWithText(FilledButton, l10n.delete));
      await tester.pumpAndSettle();

      expect(downloads.removed, [same(completed)]);
      expect(container.read(downloadedFilesProvider)[_episode.url], isNull);
      expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
      expect(find.byIcon(Icons.save_alt_rounded), findsOneWidget);
      expect(
        container.read(playerControllerProvider).activeEpisodeUrl,
        _episode.url,
      );
    },
  );

  testWidgets(
    'a refused delete retains the row and reports the existing error',
    (tester) async {
      final notifications = NotificationService();
      addTearDown(notifications.dispose);
      final downloads = _Downloads([
        _download(),
      ], error: StateError('Unable to delete download while it is in use'));
      await _pumpPanel(
        tester,
        downloads: downloads,
        notifications: notifications,
      );

      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(AlertDialog)),
      )!;
      await tester.tap(find.widgetWithText(FilledButton, l10n.delete));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
      expect(
        notifications.toasts.single.message,
        'Unable to delete download while it is in use',
      );
      notifications.clearToasts();
      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
    },
  );

  testWidgets('refresh failure after deletion is reported without escaping', (
    tester,
  ) async {
    final notifications = NotificationService();
    addTearDown(notifications.dispose);
    final files = _Files(true);
    final container = await _pumpPanel(
      tester,
      downloads: _Downloads([_download()]),
      files: files,
      notifications: notifications,
    );
    files.checkError = StateError('Download status could not be refreshed');

    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(AlertDialog)))!;
    await tester.tap(find.widgetWithText(FilledButton, l10n.delete));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(container.read(downloadsProvider).requireValue, isEmpty);
    expect(
      notifications.toasts.single.message,
      'Download status could not be refreshed',
    );
    notifications.clearToasts();
    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadManagementDialog), findsOneWidget);
  });

  testWidgets('delete stays guarded until the local-file refresh finishes', (
    tester,
  ) async {
    final files = _Files(true);
    await _pumpPanel(
      tester,
      downloads: _Downloads([_download()]),
      files: files,
    );
    files.pendingCheck = Completer<void>();

    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(AlertDialog)))!;
    await tester.tap(find.widgetWithText(FilledButton, l10n.delete));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    files.pendingCheck!.complete();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.save_alt_rounded), findsOneWidget);
  });

  testWidgets('a cached-only completed file keeps its management delete path', (
    tester,
  ) async {
    await _pumpPanel(
      tester,
      downloads: _Downloads([]),
      files: _Files(true, cacheOnly: true),
    );

    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pumpAndSettle();

    expect(find.byType(DownloadManagementDialog), findsOneWidget);
    final l10n = AppLocalizations.of(tester.element(find.byType(AlertDialog)))!;
    expect(find.text(l10n.videoAlreadyDownloadedPrompt), findsOneWidget);
  });

  testWidgets('an undownloaded episode keeps its download action', (
    tester,
  ) async {
    final container = await _pumpPanel(
      tester,
      downloads: _Downloads([]),
      cached: false,
    );

    expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
    await tester.tap(find.byIcon(Icons.save_alt_rounded));
    await tester.pump();
    expect((container.read(downloadLauncherProvider) as _Launcher).launched, [
      _episode.url,
    ]);
    expect(find.byType(AlertDialog), findsNothing);
  });

  for (final status in [TaskStatus.running, TaskStatus.paused]) {
    testWidgets('$status retains its progress control and dialog', (
      tester,
    ) async {
      await _pumpPanel(
        tester,
        downloads: _Downloads([_download(status: status)]),
      );

      expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
      if (status == TaskStatus.paused) {
        expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      } else {
        expect(find.text('40%'), findsOneWidget);
      }
      await tester.tap(find.byType(EpisodeActionChip));
      await tester.pump();
      expect(find.byType(DownloadProgressDialog), findsOneWidget);
      expect(
        tester
            .widget<DownloadProgressDialog>(find.byType(DownloadProgressDialog))
            .trackingUrl,
        'episode-nine-logical',
      );
    });
  }
}
