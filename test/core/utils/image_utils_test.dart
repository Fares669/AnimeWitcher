import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:animewitcher/core/network/poster_cache.dart';
import 'package:animewitcher/core/utils/image_utils.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);

  final String root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

const _coldUrl = 'https://unused.invalid/cold-poster.png';
const _warmUrl = 'https://unused.invalid/warm-poster.png';

Future<int> _thumbnailHeight(String url) {
  final provider = ResizeImage(
    CachedNetworkImageProvider(url, cacheManager: posterCacheManager),
    width: 16,
  );
  final stream = provider.resolve(ImageConfiguration.empty);
  final result = Completer<int>();
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      try {
        result.complete(info.image.height);
      } finally {
        info.dispose();
        stream.removeListener(listener);
      }
    },
    onError: (error, stack) {
      stream.removeListener(listener);
      result.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  return result.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late PathProviderPlatform originalPaths;
  late BaseCacheManager defaultCache;
  final requests = <String, int>{};

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('portrait_probe_cache_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);

    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xffb36c27), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(32, 20);
    picture.dispose();
    final Uint8List png;
    try {
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      png = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }

    // Each real cache manager captures its HTTP client on initialization;
    // supply only synthetic responses, without opening a network socket.
    await http.runWithClient(
      () async {
        defaultCache = CachedNetworkImageProvider.defaultCacheManager;
        for (final cache in [posterCacheManager, defaultCache]) {
          await cache.getFileFromCache('fixture-initialization');
        }
      },
      () => MockClient((request) async {
        final url = request.url.toString();
        requests.update(url, (count) => count + 1, ifAbsent: () => 1);
        return http.Response.bytes(
          png,
          200,
          headers: {
            HttpHeaders.cacheControlHeader: 'max-age=3600',
            HttpHeaders.contentTypeHeader: 'image/png',
          },
        );
      }),
    );
  });

  tearDownAll(() async {
    imageCache
      ..clear()
      ..clearLiveImages();
    try {
      await posterCacheManager.dispose();
      await defaultCache.dispose();
      await directory.delete(recursive: true);
    } finally {
      PathProviderPlatform.instance = originalPaths;
    }
  });

  for (final (url, warm) in [(_coldUrl, false), (_warmUrl, true)]) {
    test(
      'probe and resized thumbnail share the original (warm: $warm)',
      () async {
        if (warm) {
          await posterCacheManager.getSingleFile(url);
          expect(requests[url], 1);
        }
        // Different ImageCache widths cannot mask a second file download.
        await Future.wait([
          expectLater(ImageUtils.isImagePortrait(url), completion(isFalse)),
          expectLater(_thumbnailHeight(url), completion(10)),
        ]);
        expect(requests[url], 1);
      },
    );
  }

  test('near square and one-pixel posters preserve orientation', () async {
    for (final (width, height, portrait) in [
      (31, 30, false),
      (30, 31, true),
      (30, 30, true),
      (2, 1, false),
      (1, 2, true),
    ]) {
      final url = 'https://unused.invalid/probe-$width-$height.png';
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawColor(const ui.Color(0xffb36c27), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(width, height);
      picture.dispose();
      try {
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await posterCacheManager.putFile(
          url,
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          fileExtension: 'png',
          maxAge: const Duration(hours: 1),
        );
      } finally {
        image.dispose();
      }
      expect(await ImageUtils.isImagePortrait(url), portrait);
      expect(requests[url], isNull);
    }
  });

  test('EXIF orientation matches the original decoded frame', () async {
    final bytes = base64Decode(
      '/9j/4AAQSkZJRgABAQAAAQABAAD/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAA'
      'ABAAYAAAAAAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8lJCIf'
      'IiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8SDc9Pjv/2wBDAQoLCw4NDhwQEB'
      'w7KCIoOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7'
      'Ozs7Ozs7Ozv/wAARCAAaACYDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAA'
      'AAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAA'
      'AAb/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCGAmVYAAAAAA'
      'AAAA//2Q==',
    );
    const url = 'https://unused.invalid/probe-rotated-jpeg.jpg';
    await posterCacheManager.putFile(
      url,
      bytes,
      fileExtension: 'jpg',
      maxAge: const Duration(hours: 1),
    );
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      try {
        expect(
          await ImageUtils.isImagePortrait(url),
          frame.image.height >= frame.image.width,
        );
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  });

  test('a broken encoded file still falls back to portrait', () async {
    const url = 'https://unused.invalid/probe-broken.png';
    // Truncated PNG header. Having encoded bytes in the shared disk cache
    // is not by itself proof a frame can be displayed.
    await posterCacheManager.putFile(
      url,
      Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
      fileExtension: 'png',
      maxAge: const Duration(hours: 1),
    );
    expect(await ImageUtils.isImagePortrait(url), isTrue);
    expect(await ImageUtils.isImagePortrait(url), isTrue);
    expect(requests[url], isNull);
  });

  test(
    'portrait probe releases its own handle without disposing cached image',
    () async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawColor(const ui.Color(0xffa76438), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(32, 21);
      picture.dispose();
      const url = 'https://unused.invalid/probe-landscape.png';
      const key = CachedNetworkImageProvider(url);
      addTearDown(() {
        imageCache.evict(key);
        image.dispose();
      });

      final completer = OneFrameImageStreamCompleter(
        Future.value(ImageInfo(image: image.clone())),
      );
      imageCache.putIfAbsent(key, () => completer);
      await Future<void>.delayed(Duration.zero);
      final ownedByTestAndCache = image.debugGetOpenHandleStackTraces()!.length;

      // A cached completer can deliver the frame during addListener itself.
      expect(await ImageUtils.isImagePortrait(url), isFalse);
      expect(await ImageUtils.isImagePortrait(url), isFalse);
      expect(
        image.debugGetOpenHandleStackTraces()!,
        hasLength(ownedByTestAndCache),
      );
    },
  );
}
