import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/subsampling/subsampling_scale_image_view.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_page_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _RejectTempPath extends PathProviderPlatform {
  @override
  Future<String?> getTemporaryPath() =>
      Future.error(PlatformException(code: 'test-no-temp'));
}

class _OnlyStreamProvider extends ImageProvider<_OnlyStreamProvider> {
  const _OnlyStreamProvider(this.frames);
  final _Frames frames;

  @override
  Future<_OnlyStreamProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _OnlyStreamProvider key,
    ImageDecoderCallback decode,
  ) => frames;
}

class _Frames extends ImageStreamCompleter {
  void show(ui.Image image) => setImage(ImageInfo(image: image.clone()));
}

ui.Image _frame() {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff552722), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(18, 21);
  picture.dispose();
  return image;
}

void main() {
  testWidgets(
    'animated page keeps size updates but releases probe frame clones',
    (tester) async {
      const path = '/unused/animewitcher-regression.gif';
      final key = FileImage(File(path));
      final first = _frame();
      final second = _frame();
      final frames = _Frames();

      imageCache.putIfAbsent(key, () => frames);
      addTearDown(() {
        imageCache.evict(key);
        first.dispose();
        second.dispose();
      });

      final dimensions = <Size>[];
      var settled = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 200,
            height: 200,
            child: MangaPageImage(
              page: MangaPage(index: 0, imageUrl: Uri.file(path).toString()),
              onImageSize: dimensions.add,
              onLoadSettled: () => settled++,
            ),
          ),
        ),
      );
      frames.show(first);
      await tester.pump();
      frames.show(second);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());

      expect(dimensions, [const Size(18, 21)]);
      expect(settled, 1);
      // The render widget has been removed. Only the test owns the superseded
      // frame; the completer still holds its handle to the newest one.
      expect(first.debugGetOpenHandleStackTraces()!, hasLength(1));
      expect(second.debugGetOpenHandleStackTraces()!, hasLength(2));
    },
  );

  testWidgets('subsampling fallback releases first and extra frames on error', (
    tester,
  ) async {
    final platform = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _RejectTempPath();
    addTearDown(() => PathProviderPlatform.instance = platform);
    final first = _frame();
    final extra = _frame();
    final frames = _Frames();
    final key = _OnlyStreamProvider(frames);
    addTearDown(() {
      imageCache.evict(key);
      first.dispose();
      extra.dispose();
    });
    final errors = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SubsamplingScaleImageView(image: key, onError: errors.add),
      ),
    );

    // The listener stays attached until the awaiting continuation starts.
    // Send both frames in the same event to exercise each ownership path.
    frames.show(first);
    frames.show(extra);
    await tester.pump();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());

    expect(errors.single, contains('test-no-temp'));
    expect(first.debugGetOpenHandleStackTraces()!, hasLength(1));
    expect(extra.debugGetOpenHandleStackTraces()!, hasLength(2));
  });
}
