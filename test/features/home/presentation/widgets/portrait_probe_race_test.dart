import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/network/poster_cache.dart';
import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:animewitcher/features/home/presentation/view_all_screen.dart';
import 'package:animewitcher/features/home/presentation/widgets/media_horizontal_list.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _LocalPaths extends PathProviderPlatform {
  _LocalPaths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _ControlledFrame extends ImageStreamCompleter {
  int attached = 0;

  @override
  void addListener(ImageStreamListener listener) {
    attached++;
    super.addListener(listener);
  }

  void fail() => reportError(
    exception: const FormatException('synthetic invalid poster'),
    silent: true,
  );

  void finish({required bool portrait}) {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const Color(0xff874128), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(portrait ? 20 : 32, portrait ? 32 : 20);
    picture.dispose();
    setImage(ImageInfo(image: image));
  }
}

String _url(String id) => 'https://unused.invalid/cycle3-portrait-$id.png';

Future<_ControlledFrame> _seedOriginalAndThumb(String id) async {
  final provider = CachedNetworkImageProvider(
    _url(id),
    cacheManager: posterCacheManager,
  );
  for (final width in [192, 256]) {
    final resized = ResizeImage(provider, width: width);
    final thumb = _ControlledFrame()..finish(portrait: true);
    imageCache.putIfAbsent(
      await resized.obtainKey(ImageConfiguration.empty),
      () => thumb,
    );
  }
  final original = _ControlledFrame();
  imageCache.putIfAbsent(provider, () => original);
  return original;
}

Widget _rail(String id, {bool livestream = true, String? title}) =>
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: MediaHorizontalList(
            title: 'Recently updated',
            mediaList: [
              MultimediaItem(
                title: title ?? id,
                url: 'https://unused.invalid/show/$id',
                posterUrl: _url(id),
                contentType: livestream
                    ? MultimediaContentType.livestream
                    : MultimediaContentType.anime,
              ),
            ],
            category: ViewAllCategory.providerContent,
            showViewAll: false,
            onTap: (_) {},
          ),
        ),
      ),
    );

bool _paintsPortrait(WidgetTester tester) =>
    tester.widget<MultimediaCard>(find.byType(MultimediaCard)).isPortrait;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late PathProviderPlatform paths;
  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('portrait_probe_race_');
    paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _LocalPaths(dir.path);
    await posterCacheManager.getFileFromCache('fixture-initialization');
  });
  tearDownAll(() async {
    await posterCacheManager.dispose();
    PathProviderPlatform.instance = paths;
    await dir.delete(recursive: true);
  });

  void handset(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final quality = highQualityArtwork.value;
    highQualityArtwork.value = true;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      debugDefaultTargetPlatformOverride = null;
      highQualityArtwork.value = quality;
      imageCache
        ..clear()
        ..clearLiveImages();
    });
  }

  testWidgets(
    'late landscape frame cannot repaint the replacement portrait rail',
    (tester) async {
      handset(tester);
      final earlier = await _seedOriginalAndThumb('old-landscape');
      final current = await _seedOriginalAndThumb('current-portrait');
      await tester.pumpWidget(_rail('old-landscape'));
      await tester.pumpWidget(_rail('current-portrait'));

      current.finish(portrait: true);
      await tester.pump();
      await tester.pump();
      expect(_paintsPortrait(tester), isTrue);

      earlier.finish(portrait: false);
      await tester.pump();
      await tester.pump();
      expect(_paintsPortrait(tester), isTrue);
    },
  );

  testWidgets('late livestream probe cannot repaint a normal anime rail', (
    tester,
  ) async {
    handset(tester);
    final earlier = await _seedOriginalAndThumb('stream-landscape');
    await _seedOriginalAndThumb('standard-anime');
    await tester.pumpWidget(_rail('stream-landscape'));
    await tester.pumpWidget(_rail('standard-anime', livestream: false));
    earlier.finish(portrait: false);
    await tester.pump();
    await tester.pump();
    expect(_paintsPortrait(tester), isTrue);
  });

  testWidgets(
    'same first poster stays on one in-flight probe across list rebuilds',
    (tester) async {
      handset(tester);
      final same = await _seedOriginalAndThumb('same-stream');
      await tester.pumpWidget(_rail('same-stream', title: 'before'));
      final initialListeners = same.attached;
      expect(initialListeners, greaterThan(1));
      for (var i = 0; i < 4; i++) {
        await tester.pumpWidget(_rail('same-stream', title: 'update $i'));
      }
      final extra = same.attached - initialListeners;
      same.finish(portrait: false);
      await tester.pump();
      await tester.pump();
      expect(_paintsPortrait(tester), isFalse);
      expect(extra, 0);
    },
  );

  testWidgets(
    'decode failure remains portrait, valid replacement can recover',
    (tester) async {
      handset(tester);
      final landscape = await _seedOriginalAndThumb('good-first');
      final broken = await _seedOriginalAndThumb('broken-frame');
      final replacement = await _seedOriginalAndThumb('good-replacement');

      await tester.pumpWidget(_rail('good-first'));
      landscape.finish(portrait: false);
      await tester.pump();
      await tester.pump();
      expect(_paintsPortrait(tester), isFalse);

      await tester.pumpWidget(_rail('broken-frame'));
      broken.fail();
      await tester.pump();
      await tester.pump();
      expect(_paintsPortrait(tester), isTrue);

      await tester.pumpWidget(_rail('good-replacement'));
      replacement.finish(portrait: false);
      await tester.pump();
      await tester.pump();
      expect(_paintsPortrait(tester), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
