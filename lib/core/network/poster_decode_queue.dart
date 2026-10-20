import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Bounds first-frame work, not image quality or the decoded image cache.
///
/// Large static images may temporarily keep their full-size native upload
/// buffers alive even when their final decoded target is a small thumbnail.
class PosterDecodeQueue {
  PosterDecodeQueue({this.concurrency = 4}) {
    if (concurrency < 1) throw ArgumentError.value(concurrency, 'concurrency');
  }

  static final shared = PosterDecodeQueue();
  final int concurrency;
  final Queue<_DecodePermit> _waiting = Queue<_DecodePermit>();
  int _active = 0;

  @visibleForTesting
  int get activeCount => _active;
  @visibleForTesting
  int get queuedCount => _waiting.length;

  _DecodePermit _acquire() {
    final permit = _DecodePermit(this);
    if (_active < concurrency) {
      _active++;
      permit._state = _PermitState.reserved;
    } else {
      permit._ready = Completer<void>();
      _waiting.add(permit);
    }
    return permit;
  }

  void _releaseSlot() {
    _active--;
    if (_waiting.isEmpty) return;
    final next = _waiting.removeFirst();
    // Reserve the transferred slot before completing the future. A newcomer
    // must not overtake this waiter or oversubscribe the native decode limit.
    _active++;
    next._state = _PermitState.reserved;
    next._ready!.complete();
  }
}

enum _PermitState { waiting, reserved, running, released }

class _DecodePermit {
  _DecodePermit(this.queue);
  final PosterDecodeQueue queue;
  _PermitState _state = _PermitState.waiting;
  Completer<void>? _ready;
  Future<void>? get ready => _ready?.future;

  void start() {
    if (_state != _PermitState.reserved) {
      throw StateError('Poster codec was disposed before decoding started.');
    }
    _state = _PermitState.running;
  }

  void cancelBeforeStart() {
    if (_state == _PermitState.waiting) {
      queue._waiting.remove(this);
      _state = _PermitState.released;
      _ready!.completeError(
        StateError('Poster codec was disposed while waiting to decode.'),
      );
    } else if (_state == _PermitState.reserved) {
      release();
    }
    // An already-started native request retains its slot until it settles.
  }

  void release() {
    if (_state == _PermitState.released) return;
    assert(_state != _PermitState.waiting);
    _state = _PermitState.released;
    queue._releaseSlot();
  }
}

/// A static codec adapter that preserves one owned frame per requested call.
///
/// It does not deduplicate FrameInfo futures, retain decoded frames, or cancel
/// work merely because a widget has scrolled away. ImageCache can still own
/// that work. Animated codecs are returned unchanged by [wrap].
class PosterDecodeCodec implements ui.Codec {
  PosterDecodeCodec._(this._delegate, this._queue);

  static ui.Codec wrap(ui.Codec codec, {PosterDecodeQueue? queue}) =>
      codec.frameCount == 1
      ? PosterDecodeCodec._(codec, queue ?? PosterDecodeQueue.shared)
      : codec;

  final ui.Codec _delegate;
  final PosterDecodeQueue _queue;
  final Set<_DecodePermit> _pending = <_DecodePermit>{};
  bool _firstFrameCompleted = false;
  bool _disposed = false;

  @override
  int get frameCount => _delegate.frameCount;
  @override
  int get repetitionCount => _delegate.repetitionCount;

  @override
  Future<ui.FrameInfo> getNextFrame() {
    if (_disposed) {
      return Future<ui.FrameInfo>.error(
        StateError('Poster codec is disposed.'),
      );
    }
    if (_firstFrameCompleted) return _delegate.getNextFrame();
    final permit = _queue._acquire();
    _pending.add(permit);
    return _firstFrame(permit);
  }

  Future<ui.FrameInfo> _firstFrame(_DecodePermit permit) async {
    try {
      final ready = permit.ready;
      if (ready != null) await ready;
      permit.start();
      final frame = await _delegate.getNextFrame();
      _firstFrameCompleted = true;
      return frame;
    } finally {
      _pending.remove(permit);
      permit.release();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final permit in _pending.toList(growable: false)) {
      permit.cancelBeforeStart();
    }
    // Native Codec protects already-started callbacks independently of its
    // Dart wrapper. Preserve immediate disposal and caller-owned frame results.
    _delegate.dispose();
  }
}
