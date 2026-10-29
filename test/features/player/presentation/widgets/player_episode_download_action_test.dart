import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/notification_service.dart';
import 'package:animewitcher/core/storage/episode_watch_repository.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/core/utils/download_time_remaining.dart';
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
final _savedFile = File('/saved/episode-nine.mp4');

DownloadItem _download({TaskStatus status = TaskStatus.complete}) =>
    DownloadItem(
      task: DownloadTask(
        taskId: 'episode-nine-task',
        url: 'https://cdn.test/9.mp4',
        filename: '9.mp4',
      ),
      item: _show,
      episode: _episode,
      logicalId: 'episode-nine-logical',
      trackingUrl: _episode.url,
      destinationPath: _savedFile.path,
      status: status,
      progress: status == TaskStatus.complete ? 1 : 0.4,
      timestamp: 1,
    );

class _Downloads extends DownloadsNotifier {
  _Downloads(this.items, {this.error});
  final List<DownloadItem> items;
  final Object? error;
  final removed = <DownloadItem>[];

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
}

class _Files extends DownloadedFiles {
  _Files(this.cached, {this.cacheOnly = false});
  final bool cached;
  final bool cacheOnly;
  Object? checkError;
  Completer<void>? pendingCheck;

  @override
  Map<String, File?> build() => {_episode.url: cached ? _savedFile : null};

  @override
  Future<void> checkFile(MultimediaItem item, {Episode? episode}) async {
    await pendingCheck?.future;
    if (checkError != null) throw checkError!;
    final completed = completedEpisodeDownload(
      ref.read(downloadsProvider).value ?? [],
      item,
      episode!,
    );
    state = {
      episode.url: cached && (completed != null || cacheOnly)
          ? _savedFile
          : null,
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

class _History extends Fake implements HistoryRepository {
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
}

class _Launcher extends DownloadLauncher {
  _Launcher(super.ref);
  final launched = <String>[];

  @override
  Future<void> launch(
    BuildContext context,
    MultimediaItem item, {
    String? episodeUrl,
    Episode? episode,
  }) async => launched.add(episodeUrl!);
}

Future<ProviderContainer> _pumpPanel(
  WidgetTester tester, {
  required _Downloads downloads,
  bool cached = true,
  _Files? files,
  NotificationService? notifications,
}) async {
  final container = ProviderContainer(
    overrides: [
      downloadsProvider.overrideWith(() => downloads),
      downloadedFilesProvider.overrideWith(() => files ?? _Files(cached)),
      playerControllerProvider.overrideWith(_Player.new),
      detailsControllerProvider(_show.url).overrideWith(_Details.new),
      historyRepositoryProvider.overrideWithValue(_History()),
      episodeWatchRepositoryProvider.overrideWithValue(_Watch()),
      downloadLauncherProvider.overrideWith((ref) => _Launcher(ref)),
      downloadProgressProvider.overrideWithValue({
        if (downloads.items.isNotEmpty)
          'episode-nine-logical': DownloadProgressData(
            taskId: downloads.items.single.id,
            progress: 0.4,
            networkSpeed: -1,
            timeRemaining: Duration.zero,
            status: downloads.items.single.status,
          ),
      }),
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
              child: PlayerEpisodesPanel(item: _show, onClose: () {}),
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
