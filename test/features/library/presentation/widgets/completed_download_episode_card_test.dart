import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:animewitcher/features/library/presentation/download_episode_artwork.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/library/presentation/widgets/completed_download_episode_card.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../../support/memory_storage_service.dart';
import '../../../../support/widget_completion.dart';

class _Storage extends MemoryStorageService {
  List<Map<String, dynamic>> snapshot = [];

  @override
  List<Map<String, dynamic>> getWatchHistory() => snapshot;

  @override
  int getEpisodeDuration(
    String url, {
    String? mainUrl,
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
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

Future<void> _mountCard(
  WidgetTester tester,
  ProviderContainer container,
  DownloadItem item,
) => tester.pumpWidget(
  UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: CompletedDownloadEpisodeCard(
          item: item,
          onPlay: () {},
          onDelete: () {},
        ),
      ),
    ),
  ),
);

void main() {
  late Directory artworkRoot;
  final originalPaths = PathProviderPlatform.instance;
  setUpAll(() async {
    artworkRoot = await Directory.systemTemp.createTemp('aw-history-card-');
    PathProviderPlatform.instance = _Paths(artworkRoot.path);
  });
  tearDownAll(() async {
    await DefaultCacheManager().dispose();
    PathProviderPlatform.instance = originalPaths;
    await artworkRoot.delete(recursive: true);
  });

  testWidgets(
    'downloaded episode badge follows the latest own-provider history',
    (tester) async {
      const url = 'https://example.test/series';
      final storage = _Storage();
      final matching = <String, dynamic>{
        'url': url,
        'provider': 'Extension A',
        'season': 1,
        'episode': 2,
      };
      final otherProvider = <String, dynamic>{
        ...matching,
        'provider': 'Extension B',
      };
      storage.snapshot = [otherProvider, matching];
      final container = ProviderContainer(
        overrides: [storageServiceProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      final item = DownloadItem(
        task: DownloadTask(
          taskId: 'video-ep2-fixture',
          url: 'https://example.test/video.mp4',
          filename: 'episode.mp4',
        ),
        status: TaskStatus.complete,
        progress: 1,
        item: MultimediaItem(
          title: 'Series',
          url: url,
          posterUrl: '',
          provider: 'Extension A',
        ),
        episode: Episode(
          name: 'Episode 2',
          url: '$url/e2',
          season: 1,
          episode: 2,
        ),
        timestamp: 1,
      );
      await _mountCard(tester, container, item);
      await tester.pumpAndSettle();
      final badge = find.text('آخر مشاهدة');
      expect(badge, findsOneWidget);

      storage.snapshot = [
        otherProvider,
        {...matching, 'episode': 1},
      ];
      container.read(watchHistoryProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(badge, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final local in [true, false]) {
    testWidgets(
      'high quality bounds the decoded ${local ? 'saved thumbnail' : 'cached fallback'}',
      (tester) async {
        tester.view.devicePixelRatio = 2;
        tester.view.physicalSize = const Size(1600, 1200);
        final previousQuality = highQualityArtwork.value;
        highQualityArtwork.value = true;
        addTearDown(() {
          tester.view.reset();
          highQualityArtwork.value = previousQuality;
          PaintingBinding.instance.imageCache
            ..clear()
            ..clearLiveImages();
        });

        const bannerUrl = 'https://example.test/high-resolution-banner.png';
        final taskId = local ? 'saved-artwork' : 'fallback-artwork';
        await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder);
          canvas.drawColor(const Color(0xffcc3300), ui.BlendMode.src);
          canvas.drawRect(
            const Rect.fromLTWH(960, 0, 960, 1080),
            ui.Paint()..color = const Color(0xff0033cc),
          );
          final picture = recorder.endRecording();
          final fullSize = await picture.toImage(1920, 1080);
          picture.dispose();
          final png = await fullSize.toByteData(format: ui.ImageByteFormat.png);
          fullSize.dispose();
          final bytes = png!.buffer.asUint8List(
            png.offsetInBytes,
            png.lengthInBytes,
          );

          if (local) {
            final file = (await downloadedEpisodeArtworkFile(taskId))!;
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes);
          } else {
            await DefaultCacheManager().putFile(
              bannerUrl,
              bytes,
              fileExtension: 'png',
            );
          }
        });

        final container = ProviderContainer(
          overrides: [storageServiceProvider.overrideWithValue(_Storage())],
        );
        addTearDown(container.dispose);
        await _mountCard(
          tester,
          container,
          DownloadItem(
            task: DownloadTask(
              taskId: taskId,
              url: 'https://example.test/video.mp4',
            ),
            status: TaskStatus.complete,
            progress: 1,
            item: MultimediaItem(
              title: 'Series',
              url: 'https://example.test/series',
              posterUrl: '',
              bannerUrl: local ? null : bannerUrl,
            ),
            episode: Episode(
              name: 'Episode 1',
              url: 'https://example.test/series/e1',
              season: 1,
              episode: 1,
            ),
            timestamp: 1,
          ),
        );

        final lookup = tester.widget<FutureBuilder<File?>>(
          find.byWidgetPredicate((widget) => widget is FutureBuilder<File?>),
        );
        final file = await pumpUntilFuture(
          tester,
          lookup.future!,
          'completed episode artwork lookup',
        );
        expect(file != null, local);
        await tester.pump();

        final thumbnail = find.byType(RawImage);
        await pumpUntil(
          tester,
          () =>
              thumbnail.evaluate().length == 1 &&
              tester.widget<RawImage>(thumbnail).image != null,
          'completed episode thumbnail decode',
        );
        final rendered = tester.widget<RawImage>(thumbnail);
        expect(tester.getSize(thumbnail), const Size(140, 78.75));
        expect(rendered.fit, BoxFit.cover);
        final decoded = rendered.image!;
        final cache = PaintingBinding.instance.imageCache;
        expect(decoded.width, 384);
        expect(decoded.height, 216);
        final rgba = await tester.runAsync(decoded.toByteData);
        int colourAt(int x, int y) =>
            rgba!.getUint32((y * decoded.width + x) * 4);
        expect(colourAt(96, 108), 0xcc3300ff);
        expect(colourAt(288, 108), 0x0033ccff);
        final provider = tester.widget<Image>(find.byType(Image)).image;
        expect(provider, isA<ResizeImage>());
        expect((provider as ResizeImage).width, 384);
        final key = await provider.obtainKey(ImageConfiguration.empty);
        expect(cache.statusForKey(key).keepAlive, isTrue);
        expect(cache.currentSize, 1);
        expect(cache.currentSizeBytes, 384 * 216 * 4);
        expect(
          find.byType(CachedNetworkImage),
          local ? findsNothing : findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
