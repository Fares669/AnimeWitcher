import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/network/poster_cache.dart';
import 'package:animewitcher/core/network/queued_poster_image_provider.dart';
import 'package:animewitcher/core/utils/artwork_host_fallback.dart';
import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:animewitcher/shared/widgets/fallback_poster_image.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octo_image/octo_image.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const _url = 'https://fixture.invalid/poster.png';
const _replacementUrl = 'https://fixture.invalid/replacement.png';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

Future<void> _seedDecodedPoster(String url, {int? width}) async {
  final provider = ResizeImage.resizeIfNeeded(
    width,
    null,
    CachedNetworkImageProvider(url, cacheManager: posterCacheManager),
  );
  final key = await provider.obtainKey(ImageConfiguration.empty);
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const Color(0xff123456), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(2, 3);
  picture.dispose();
  // Both providers must reuse the same decoded-cache key, without loading files.
  PaintingBinding.instance.imageCache.putIfAbsent(
    key,
    () => OneFrameImageStreamCompleter(
      SynchronousFuture<ImageInfo>(ImageInfo(image: image)),
    ),
  );
}

void _configure(
  WidgetTester tester, {
  Size size = const Size(1000, 1400),
  bool highQuality = false,
}) {
  final previousQuality = highQualityArtwork.value;
  final previousFallback = artworkFallbackEnabled.value;
  final previousUnreachable = malArtworkUnreachable.value;
  highQualityArtwork.value = highQuality;
  artworkFallbackEnabled.value = false;
  malArtworkUnreachable.value = false;
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = size * 2;
  addTearDown(() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    highQualityArtwork.value = previousQuality;
    artworkFallbackEnabled.value = previousFallback;
    malArtworkUnreachable.value = previousUnreachable;
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
}

Widget _app(Widget child) => ProviderScope(
  child: MaterialApp(
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(body: Center(child: child)),
    ),
  ),
);

Widget _card() => SizedBox(
  height: 360,
  child: MultimediaCard(
    imageUrl: _url,
    title: 'Poster title',
    subtitle: 'مسلسل',
    heroTag: 'poster-scope',
    onTap: () {},
  ),
);

CachedNetworkImageProvider _source(OctoImage image) {
  final provider = image.image;
  return (provider is ResizeImage ? provider.imageProvider : provider)
      as CachedNetworkImageProvider;
}

void _expectImagePath(
  WidgetTester tester, {
  required bool queued,
  required int? decodeWidth,
  String url = _url,
}) {
  final octo = tester.widget<OctoImage>(find.byType(OctoImage));
  final source = _source(octo);
  expect(source.url, url);
  expect(source.cacheManager, same(posterCacheManager));
  expect(source is QueuedPosterImageProvider, queued);
  expect(
    find.byType(CachedNetworkImage),
    queued ? findsNothing : findsOneWidget,
  );
  expect(find.byKey(ValueKey<String>('$url#0')), findsOneWidget);
  if (decodeWidth == null) {
    expect(octo.image, isNot(isA<ResizeImage>()));
  } else {
    expect(octo.image, isA<ResizeImage>());
    final resized = octo.image as ResizeImage;
    expect(resized.width, decodeWidth);
    expect(resized.height, isNull);
    expect(resized.allowUpscaling, isFalse);
  }
  expect(octo.fadeInDuration, const Duration(milliseconds: 120));
  expect(octo.fadeOutDuration, Duration.zero);
  expect(octo.gaplessPlayback, isTrue);
  expect(octo.filterQuality, FilterQuality.medium);
  expect(octo.alignment, Alignment.center);
  expect(octo.fit, BoxFit.cover);
  expect(octo.width, double.infinity);
  expect(octo.height, double.infinity);
  expect(
    Directionality.of(tester.element(find.byType(OctoImage))),
    TextDirection.rtl,
  );
  expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform originalPaths;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('queued_poster_scope_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    // The production cache initializes storage eagerly, outside widget fake time.
    await posterCacheManager.config.repo.open();
    await posterCacheManager.config.repo.close();
    await posterCacheManager.config.fileSystem.createFile('initialization');
  });

  tearDownAll(() async {
    await posterCacheManager.dispose();
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  testWidgets('standard desktop cards use the queued resized provider', (
    tester,
  ) async {
    _configure(tester);
    await _seedDecodedPoster(_url, width: 400);
    await tester.pumpWidget(_app(_card()));

    final poster = tester.widget<FallbackPosterImage>(
      find.byType(FallbackPosterImage),
    );
    expect(poster.queueStaticPosterDecode, isTrue);
    expect(poster.memCacheWidth, 400);
    _expectImagePath(tester, queued: true, decodeWidth: 400);
    expect(tester.getSize(find.byType(MultimediaCard)).width, 200);
    final title = tester.widget<Text>(find.text('Poster title'));
    expect(title.textDirection, TextDirection.ltr);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('high-quality desktop cards keep the original provider', (
    tester,
  ) async {
    _configure(tester, highQuality: true);
    await _seedDecodedPoster(_url);
    await tester.pumpWidget(_app(_card()));

    final poster = tester.widget<FallbackPosterImage>(
      find.byType(FallbackPosterImage),
    );
    expect(poster.queueStaticPosterDecode, isFalse);
    expect(poster.memCacheWidth, isNull);
    _expectImagePath(tester, queued: false, decodeWidth: null);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets(
    'standard handset cards keep the original resized provider',
    (tester) async {
      _configure(tester, size: const Size(400, 600));
      await _seedDecodedPoster(_url, width: 260);
      await tester.pumpWidget(_app(_card()));

      final poster = tester.widget<FallbackPosterImage>(
        find.byType(FallbackPosterImage),
      );
      expect(poster.queueStaticPosterDecode, isFalse);
      expect(poster.memCacheWidth, 260);
      _expectImagePath(tester, queued: false, decodeWidth: 260);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets('a desktop-sized Android window does not opt into the queue', (
    tester,
  ) async {
    _configure(tester);
    await _seedDecodedPoster(_url, width: 400);
    await tester.pumpWidget(_app(_card()));
    _expectImagePath(tester, queued: false, decodeWidth: 400);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('changing artwork quality switches the mounted card path', (
    tester,
  ) async {
    _configure(tester);
    await _seedDecodedPoster(_url, width: 400);
    await _seedDecodedPoster(_url);
    await tester.pumpWidget(_app(_card()));
    _expectImagePath(tester, queued: true, decodeWidth: 400);

    highQualityArtwork.value = true;
    await tester.pump();
    _expectImagePath(tester, queued: false, decodeWidth: null);

    highQualityArtwork.value = false;
    await tester.pump();
    _expectImagePath(tester, queued: true, decodeWidth: 400);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('a non-card banner remains opt-out even with a decode width', (
    tester,
  ) async {
    _configure(tester);
    await _seedDecodedPoster(_url, width: 400);
    await tester.pumpWidget(
      _app(
        FallbackPosterImage(
          imageUrl: _url,
          malId: null,
          preferBanner: true,
          memCacheWidth: 400,
          width: double.infinity,
          height: double.infinity,
          placeholder: (_) => const SizedBox(),
          errorWidget: (_) => const Text('image error'),
        ),
      ),
    );
    _expectImagePath(tester, queued: false, decodeWidth: 400);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  for (final queued in <bool>[false, true]) {
    testWidgets('queue=$queued preserves explicit image options and URL keys', (
      tester,
    ) async {
      _configure(tester);
      for (final url in [_url, _replacementUrl]) {
        await _seedDecodedPoster(url, width: 240);
      }
      Widget poster(String url) => FallbackPosterImage(
        imageUrl: url,
        malId: null,
        queueStaticPosterDecode: queued,
        width: 120,
        height: 80,
        memCacheWidth: 240,
        fit: BoxFit.contain,
        alignment: Alignment.topRight,
        filterQuality: FilterQuality.high,
        fadeInDuration: const Duration(milliseconds: 175),
        placeholder: (_) => const SizedBox(),
        errorWidget: (_) => const Text('image error'),
      );

      for (final url in [_url, _replacementUrl]) {
        await tester.pumpWidget(_app(poster(url)));
        final octo = tester.widget<OctoImage>(find.byType(OctoImage));
        expect(_source(octo) is QueuedPosterImageProvider, queued);
        expect(_source(octo).url, url);
        expect(_source(octo).cacheManager, same(posterCacheManager));
        expect(find.byKey(ValueKey<String>('$url#0')), findsOneWidget);
        expect(octo.fadeInDuration, const Duration(milliseconds: 175));
        expect(octo.fadeOutDuration, Duration.zero);
        expect(octo.gaplessPlayback, isTrue);
        expect((octo.image as ResizeImage).width, 240);
        final image = tester.widget<Image>(find.byType(Image));
        expect(image.width, 120);
        expect(image.height, 80);
        expect(image.fit, BoxFit.contain);
        expect(image.alignment, Alignment.topRight);
        expect(image.filterQuality, FilterQuality.high);
        expect(image.matchTextDirection, isFalse);
        expect(tester.getSize(find.byType(RawImage)), const Size(120, 80));
        expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
        expect(find.text('image error'), findsNothing);
        expect(tester.takeException(), isNull);
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  }
}
