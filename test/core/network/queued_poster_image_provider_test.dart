import 'dart:async';
import 'dart:ui' as ui;

import 'package:animewitcher/core/network/queued_poster_image_provider.dart';
import 'package:animewitcher/core/network/poster_decode_queue.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/memory.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

class _Cache extends BaseCacheManager {
  final events = StreamController<FileResponse>();
  String? requestedUrl;
  String? requestedKey;
  Map<String, String>? requestedHeaders;
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) {
    requestedUrl = url;
    requestedKey = key;
    requestedHeaders = headers;
    return events.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageCache extends _Cache with ImageCacheManager {
  int? diskWidth;
  int? diskHeight;
  @override
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  }) {
    diskWidth = maxWidth;
    diskHeight = maxHeight;
    return getFileStream(
      url,
      key: key,
      headers: headers,
      withProgress: withProgress,
    );
  }
}

class _Frame implements ui.FrameInfo {
  _Frame(this.image);
  @override
  final ui.Image image;
  @override
  Duration get duration => Duration.zero;
}

class _Codec implements ui.Codec {
  _Codec();
  @override
  final int frameCount = 1;
  @override
  int get repetitionCount => 0;
  final requests = <Completer<ui.FrameInfo>>[];
  int disposals = 0;
  @override
  Future<ui.FrameInfo> getNextFrame() {
    final result = Completer<ui.FrameInfo>();
    requests.add(result);
    return result.future;
  }

  void finish(ui.Image image) => requests
      .firstWhere((r) => !r.isCompleted)
      .complete(_Frame(image.clone()));
  @override
  void dispose() => disposals++;
}

Future<void> _flush() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

ui.Image _image(int width) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final result = picture.toImageSync(width, 2);
  picture.dispose();
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('preserves symmetric decoded cache key equality', () async {
    const base = CachedNetworkImageProvider(
      'https://fixture.invalid/a',
      cacheKey: 'same',
      scale: 2,
      maxWidth: 300,
    );
    final queued = QueuedPosterImageProvider.withCache(
      'https://fixture.invalid/b',
      cacheManager: _Cache(),
      cacheKey: 'same',
      scale: 2,
      maxWidth: 300,
    );
    expect(base, queued);
    expect(queued, base);
    expect(base.hashCode, queued.hashCode);
    expect(
      await const ResizeImage(
        base,
        width: 178,
      ).obtainKey(ImageConfiguration.empty),
      await ResizeImage(queued, width: 178).obtainKey(ImageConfiguration.empty),
    );
    expect(
      await ResizeImage(queued, width: 179).obtainKey(ImageConfiguration.empty),
      isNot(
        await const ResizeImage(
          base,
          width: 178,
        ).obtainKey(ImageConfiguration.empty),
      ),
    );
  });

  for (final legacy in <bool>[false, true]) {
    test(
      'forwards ${legacy ? 'loadBuffer' : 'loadImage'} resize callback and cache options',
      () async {
        final cache = _Cache();
        final file = MemoryFileSystem().file('/poster')
          ..writeAsBytesSync([1, 2, 3]);
        final native = _Codec();
        final provider = QueuedPosterImageProvider.withCache(
          'https://fixture.invalid/a',
          cacheManager: cache,
          cacheKey: 'key',
          headers: const {'X-Fixture': 'yes'},
        );
        final resized = ResizeImage(
          provider,
          width: 178,
          height: 267,
          allowUpscaling: false,
        );
        final key = await resized.obtainKey(ImageConfiguration.empty);
        var decoded = false;
        final ImageStreamCompleter completer;
        if (legacy) {
          // ignore: deprecated_member_use
          completer = resized.loadBuffer(key, (
            buffer, {
            cacheWidth,
            cacheHeight,
            bool? allowUpscaling,
          }) async {
            expect(buffer.length, 3);
            expect(cacheWidth, 178);
            expect(cacheHeight, 267);
            expect(allowUpscaling, false);
            decoded = true;
            buffer.dispose();
            return native;
          });
        } else {
          completer = resized.loadImage(key, (buffer, {getTargetSize}) async {
            expect(buffer.length, 3);
            final target = getTargetSize!(1200, 1800);
            expect(target.width, 178);
            expect(target.height, 267);
            decoded = true;
            buffer.dispose();
            return native;
          });
        }
        final errors = <Object>[];
        final widths = <int>[];
        final listener = ImageStreamListener((info, _) {
          widths.add(info.image.width);
          info.dispose();
        }, onError: (Object error, StackTrace? stack) => errors.add(error));
        completer.addListener(listener);
        cache.events.add(
          FileInfo(
            file,
            FileSource.Cache,
            DateTime.now().add(const Duration(days: 1)),
            provider.url,
          ),
        );
        await _flush();
        expect(decoded, isTrue);
        expect(cache.requestedUrl, provider.url);
        expect(cache.requestedKey, 'key');
        expect(cache.requestedHeaders, const {'X-Fixture': 'yes'});
        expect(native.requests, hasLength(1));
        final source = _image(2);
        native.finish(source);
        await _flush();
        expect(widths, [2]);
        expect(errors, isEmpty);
        completer.removeListener(listener);
        await cache.events.close();
        source.dispose();
      },
    );
  }

  for (final (source, fresh, eligible) in <(FileSource, bool, bool)>[
    (FileSource.Cache, true, true),
    (FileSource.Online, true, true),
    (FileSource.NA, true, false),
    (FileSource.Cache, false, false),
  ]) {
    test(
      '$source fresh=$fresh selects queue eligibility conservatively',
      () async {
        final blockers = List.generate(4, (_) => _Codec());
        final adapters = blockers.map(PosterDecodeCodec.wrap).toList();
        final blocked = adapters.map((c) => c.getNextFrame()).toList();
        final cache = _Cache();
        final file = MemoryFileSystem().file('/fresh')..writeAsBytesSync([1]);
        final native = _Codec();
        final provider = QueuedPosterImageProvider.withCache(
          'https://fixture.invalid/fresh',
          cacheManager: cache,
        );
        final completer = provider.loadImage(provider, (
          buffer, {
          getTargetSize,
        }) async {
          buffer.dispose();
          return native;
        });
        final received = <int>[];
        final errors = <Object>[];
        final listener = ImageStreamListener((info, _) {
          received.add(info.image.width);
          info.dispose();
        }, onError: (Object error, StackTrace? stack) => errors.add(error));
        completer.addListener(listener);
        cache.events.add(
          FileInfo(
            file,
            source,
            fresh
                ? DateTime.now().add(const Duration(days: 1))
                : DateTime.now(),
            provider.url,
          ),
        );
        await _flush();
        expect(native.requests, eligible ? isEmpty : hasLength(1));
        expect(PosterDecodeQueue.shared.queuedCount, eligible ? 1 : 0);
        final image = _image(2);
        blockers[0].finish(image);
        (await blocked[0]).image.dispose();
        await _flush();
        expect(native.requests, hasLength(1));
        native.finish(image);
        await _flush();
        expect(received, [2]);
        expect(errors, isEmpty);
        for (var i = 1; i < blockers.length; i++) {
          blockers[i].finish(image);
          (await blocked[i]).image.dispose();
        }
        for (final adapter in adapters) {
          adapter.dispose();
        }
        completer.removeListener(listener);
        await cache.events.close();
        image.dispose();
        expect(PosterDecodeQueue.shared.activeCount, 0);
        expect(PosterDecodeQueue.shared.queuedCount, 0);
      },
    );
  }

  test(
    'forwards source stream errors without requesting or holding a slot',
    () async {
      final cache = _Cache();
      final provider = QueuedPosterImageProvider.withCache(
        'https://fixture.invalid/error',
        cacheManager: cache,
      );
      var decoded = false;
      final completer = provider.loadImage(provider, (
        buffer, {
        getTargetSize,
      }) async {
        decoded = true;
        buffer.dispose();
        return _Codec();
      });
      final errors = <Object>[];
      final listener = ImageStreamListener(
        (info, _) => info.dispose(),
        onError: (Object error, StackTrace? stack) => errors.add(error),
      );
      completer.addListener(listener);
      final failure = StateError('Fixture cache failure');
      cache.events.addError(failure, StackTrace.current);
      await _flush();
      expect(errors, [same(failure)]);
      expect(decoded, isFalse);
      expect(PosterDecodeQueue.shared.activeCount, 0);
      expect(PosterDecodeQueue.shared.queuedCount, 0);
      completer.removeListener(listener);
      await cache.events.close();
    },
  );

  test(
    'disk-resize requests retain ImageCacheManager route and bypass queue',
    () async {
      final blockers = List.generate(4, (_) => _Codec());
      final adapters = blockers.map(PosterDecodeCodec.wrap).toList();
      final blocked = adapters.map((c) => c.getNextFrame()).toList();
      final cache = _ImageCache();
      final file = MemoryFileSystem().file('/disk-sized')
        ..writeAsBytesSync([1]);
      final native = _Codec();
      final provider = QueuedPosterImageProvider.withCache(
        'https://fixture.invalid/disk-sized',
        cacheManager: cache,
        maxWidth: 123,
        maxHeight: 234,
      );
      final completer = provider.loadImage(provider, (
        buffer, {
        getTargetSize,
      }) async {
        buffer.dispose();
        return native;
      });
      final widths = <int>[];
      final errors = <Object>[];
      final listener = ImageStreamListener((info, _) {
        widths.add(info.image.width);
        info.dispose();
      }, onError: (Object error, StackTrace? stack) => errors.add(error));
      completer.addListener(listener);
      cache.events.add(
        FileInfo(
          file,
          FileSource.Cache,
          DateTime.now().add(const Duration(days: 1)),
          provider.url,
        ),
      );
      await _flush();
      expect(cache.diskWidth, 123);
      expect(cache.diskHeight, 234);
      expect(native.requests, hasLength(1));
      expect(PosterDecodeQueue.shared.queuedCount, 0);
      final image = _image(2);
      native.finish(image);
      await _flush();
      expect(widths, [2]);
      expect(errors, isEmpty);
      for (final blocker in blockers) {
        blocker.finish(image);
      }
      for (final frame in blocked) {
        (await frame).image.dispose();
      }
      for (final adapter in adapters) {
        adapter.dispose();
      }
      completer.removeListener(listener);
      await cache.events.close();
      image.dispose();
      expect(PosterDecodeQueue.shared.activeCount, 0);
    },
  );

  for (final queued in <bool>[false, true]) {
    for (final reattach in <bool>[false, true]) {
      test(
        '${queued ? 'candidate' : 'existing'} stale refresh reattach=$reattach bypasses queue and preserves existing ordering',
        () async {
          // Occupy the shared limiter. Expired resolutions must not join it.
          final blockers = List.generate(4, (_) => _Codec());
          final blockerAdapters = blockers.map(PosterDecodeCodec.wrap).toList();
          final blockedFrames = blockerAdapters
              .map((c) => c.getNextFrame())
              .toList();
          final cache = _Cache();
          final fs = MemoryFileSystem();
          final oldFile = fs.file('/old')..writeAsBytesSync([1]);
          final newFile = fs.file('/new')..writeAsBytesSync([2]);
          final oldCodec = _Codec();
          final newCodec = _Codec();
          final natives = <_Codec>[oldCodec, newCodec];
          var decodeCalls = 0;
          final CachedNetworkImageProvider provider = queued
              ? QueuedPosterImageProvider.withCache(
                  'https://fixture.invalid/refresh',
                  cacheManager: cache,
                )
              : CachedNetworkImageProvider(
                  'https://fixture.invalid/refresh',
                  cacheManager: cache,
                );
          final completer = provider.loadImage(provider, (
            buffer, {
            getTargetSize,
          }) async {
            buffer.dispose();
            return natives[decodeCalls++];
          });
          final widths = <int>[];
          final errors = <Object>[];
          final listener = ImageStreamListener((info, _) {
            widths.add(info.image.width);
            info.dispose();
          }, onError: (Object error, StackTrace? stack) => errors.add(error));
          completer.addListener(listener);
          cache.events.add(
            FileInfo(
              oldFile,
              FileSource.Cache,
              DateTime.now().subtract(const Duration(days: 1)),
              provider.url,
            ),
          );
          await _flush();
          expect(oldCodec.requests, hasLength(1));
          final handle = completer.keepAlive();
          if (reattach) {
            completer.removeListener(listener);
            completer.addListener(listener);
            await _flush();
            expect(oldCodec.requests, hasLength(2));
          }
          cache.events.add(
            FileInfo(
              newFile,
              FileSource.Online,
              DateTime.now().add(const Duration(days: 1)),
              provider.url,
            ),
          );
          await _flush();
          final oldImage = _image(2);
          final freshImage = _image(3);
          // Adversarial order: if permitted to start, fresh decoding finishes first.
          expect(newCodec.requests, hasLength(1));
          newCodec.finish(freshImage);
          await _flush();
          for (var i = 0; i < (reattach ? 2 : 1); i++) {
            oldCodec.finish(oldImage);
          }
          await _flush();
          if (newCodec.requests.any((r) => !r.isCompleted)) {
            newCodec.finish(freshImage);
          }
          await _flush();
          expect(decodeCalls, 2);
          // The package's pre-existing out-of-order refresh behavior is recorded
          // here, not fixed by this RAM change. The candidate must not add queue
          // delay to either expired or fresh codec in this refreshing resolution.
          expect(widths, [3, ...List<int>.filled(reattach ? 2 : 1, 2)]);
          expect(errors, isEmpty);
          for (final blocker in blockers) {
            blocker.finish(oldImage);
          }
          for (final frame in blockedFrames) {
            (await frame).image.dispose();
          }
          for (final adapter in blockerAdapters) {
            adapter.dispose();
          }
          expect(PosterDecodeQueue.shared.activeCount, 0);
          expect(PosterDecodeQueue.shared.queuedCount, 0);
          completer.removeListener(listener);
          handle.dispose();
          await cache.events.close();
          oldImage.dispose();
          freshImage.dispose();
        },
      );
    }
  }
}
