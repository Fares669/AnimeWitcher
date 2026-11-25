import 'dart:ui' as ui;

import 'package:animewitcher/core/utils/image_utils.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
