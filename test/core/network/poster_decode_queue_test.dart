import 'dart:async';
import 'dart:ui' as ui;

import 'package:animewitcher/core/network/poster_decode_queue.dart';
import 'package:flutter_test/flutter_test.dart';

class _Frame implements ui.FrameInfo {
  _Frame(this.image);
  @override
  final ui.Image image;
  @override
  Duration get duration => Duration.zero;
}

class _Codec implements ui.Codec {
  _Codec({this.frameCount = 1});
  @override
  final int frameCount;
  @override
  int get repetitionCount => frameCount == 1 ? 0 : -1;
  final requests = <Completer<ui.FrameInfo>>[];
  int disposals = 0;
  bool throwSynchronously = false;
  @override
  Future<ui.FrameInfo> getNextFrame() {
    if (throwSynchronously) throw StateError('Synchronous decoder failure');
    final result = Completer<ui.FrameInfo>();
    requests.add(result);
    return result.future;
  }

  void finish(ui.Image image) => requests
      .firstWhere((r) => !r.isCompleted)
      .complete(_Frame(image.clone()));
  void fail() => requests
      .firstWhere((r) => !r.isCompleted)
      .completeError(StateError('Asynchronous decoder failure'));
  @override
  void dispose() => disposals++;
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ui.Image image;
  setUp(() {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
    final picture = recorder.endRecording();
    image = picture.toImageSync(2, 2);
    picture.dispose();
  });
  tearDown(() => image.dispose());

  test(
    'requires positive concurrency and leaves animated codecs untouched',
    () {
      expect(() => PosterDecodeQueue(concurrency: 0), throwsArgumentError);
      final animated = _Codec(frameCount: 2);
      expect(PosterDecodeCodec.wrap(animated), same(animated));
      expect(animated.disposals, 0);
    },
  );

  test('bounds initial native requests, transfers FIFO, and drains', () async {
    final queue = PosterDecodeQueue(concurrency: 2);
    final delegates = List.generate(4, (_) => _Codec());
    final codecs = delegates
        .map((c) => PosterDecodeCodec.wrap(c, queue: queue))
        .toList();
    final first = codecs[0].getNextFrame();
    final second = codecs[1].getNextFrame();
    final third = codecs[2].getNextFrame();
    expect(queue.activeCount, 2);
    expect(queue.queuedCount, 1);
    expect(delegates[2].requests, isEmpty);
    delegates[0].finish(image);
    final fourth = first.then((frame) {
      frame.image.dispose();
      return codecs[3].getNextFrame();
    });
    await _flush();
    expect(delegates[2].requests, hasLength(1));
    expect(delegates[3].requests, isEmpty);
    expect(queue.activeCount, 2);
    delegates[1].finish(image);
    (await second).image.dispose();
    await _flush();
    expect(delegates[3].requests, hasLength(1));
    delegates[2].finish(image);
    delegates[3].finish(image);
    (await third).image.dispose();
    (await fourth).image.dispose();
    expect(queue.activeCount, 0);
    expect(queue.queuedCount, 0);
    for (final codec in codecs) {
      codec.dispose();
    }
  });

  test('concurrent initial calls own distinct frames, cached calls bypass', () async {
    final queue = PosterDecodeQueue(concurrency: 1);
    final native = _Codec();
    final codec = PosterDecodeCodec.wrap(native, queue: queue);
    final first = codec.getNextFrame();
    final second = codec.getNextFrame();
    expect(native.requests, hasLength(1));
    native.finish(image);
    final one = await first;
    await _flush();
    expect(native.requests, hasLength(2));
    native.finish(image);
    final two = await second;
    expect(identical(one.image, two.image), isFalse);
    one.image.dispose();
    // Disposing one caller's frame must not invalidate another caller's handle.
    expect(two.image.debugDisposed, isFalse);
    expect(two.image.width, 2);
    two.image.dispose();
    final blocker = _Codec();
    final blocked = PosterDecodeCodec.wrap(
      blocker,
      queue: queue,
    ).getNextFrame();
    final cached = codec.getNextFrame();
    expect(native.requests, hasLength(3));
    expect(queue.activeCount, 1);
    native.finish(image);
    (await cached).image.dispose();
    blocker.finish(image);
    (await blocked).image.dispose();
    codec.dispose();
    expect(queue.activeCount, 0);
  });

  test(
    'both synchronous and asynchronous errors release slots for retry',
    () async {
      final queue = PosterDecodeQueue(concurrency: 1);
      final native = _Codec()..throwSynchronously = true;
      final codec = PosterDecodeCodec.wrap(native, queue: queue);
      await expectLater(codec.getNextFrame(), throwsStateError);
      expect(queue.activeCount, 0);
      native.throwSynchronously = false;
      final failed = codec.getNextFrame();
      final observed = expectLater(failed, throwsStateError);
      native.fail();
      await observed;
      expect(queue.activeCount, 0);
      final retry = codec.getNextFrame();
      native.finish(image);
      (await retry).image.dispose();
      expect(queue.activeCount, 0);
      codec.dispose();
    },
  );

  test(
    'dispose cancels a transferred permit before its waiter starts',
    () async {
      final queue = PosterDecodeQueue(concurrency: 1);
      final nativeA = _Codec();
      final nativeB = _Codec();
      final a = PosterDecodeCodec.wrap(nativeA, queue: queue);
      final b = PosterDecodeCodec.wrap(nativeB, queue: queue);
      final first = a.getNextFrame();
      final waiting = b.getNextFrame();
      final observed = expectLater(waiting, throwsStateError);
      // The wrapper's await was registered first: it transfers the slot, then
      // this callback cancels B before B's queued continuation starts.
      final cancel = nativeA.requests.single.future.then((_) => b.dispose());
      nativeA.finish(image);
      (await first).image.dispose();
      await cancel;
      await observed;
      expect(nativeB.requests, isEmpty);
      expect(nativeB.disposals, 1);
      expect(queue.activeCount, 0);
      expect(queue.queuedCount, 0);
      a.dispose();
    },
  );

  test(
    'dispose rejects queued/new calls, without releasing running native work',
    () async {
      final queue = PosterDecodeQueue(concurrency: 1);
      final nativeA = _Codec();
      final nativeB = _Codec();
      final a = PosterDecodeCodec.wrap(nativeA, queue: queue);
      final b = PosterDecodeCodec.wrap(nativeB, queue: queue);
      final running = a.getNextFrame();
      final waiting = b.getNextFrame();
      final observed = expectLater(waiting, throwsStateError);
      b.dispose();
      b.dispose();
      await observed;
      expect(nativeB.disposals, 1);
      expect(nativeB.requests, isEmpty);
      expect(queue.queuedCount, 0);
      expect(queue.activeCount, 1);
      await expectLater(b.getNextFrame(), throwsStateError);
      a.dispose();
      a.dispose();
      expect(nativeA.disposals, 1);
      expect(queue.activeCount, 1);
      nativeA.finish(image);
      final owned = await running;
      expect(owned.image.debugDisposed, isFalse);
      owned.image.dispose();
      expect(queue.activeCount, 0);
    },
  );
}
