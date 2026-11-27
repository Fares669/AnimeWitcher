import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Required parameters to decode an image region
class DecodeParams {
  final String filePath;
  final int left;
  final int top;
  final int right;
  final int bottom;
  final int sampleSize;
  final bool cropBorders;

  DecodeParams({
    required this.filePath,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.sampleSize,
    this.cropBorders = false,
  });

  int get pixelWidth => (right - left) ~/ sampleSize;
  int get pixelHeight => (bottom - top) ~/ sampleSize;
  int get pixelBytes => pixelWidth * pixelHeight * 4;

  Map<String, dynamic> toJson() => {
    "filePath": filePath,
    "left": left,
    "top": top,
    "right": right,
    "bottom": bottom,
    "sampleSize": sampleSize,
    "cropBorders": cropBorders,
  };
  factory DecodeParams.fromJson(Map<String, dynamic> json) {
    return DecodeParams(
      bottom: json['bottom'] as int,
      filePath: json['filePath'] as String,
      left: json['left'] as int,
      top: json['top'] as int,
      right: json['right'] as int,
      sampleSize: json['sampleSize'] as int,
      cropBorders: json['cropBorders'] as bool? ?? false,
    );
  }
}

/// Owns the native output pixels and their admission budget. Consumers must
/// dispose unused pixels, or hand the result to [consumeImage].
class DecodeResult {
  DecodeResult({this.error, this.width = 0, this.height = 0})
    : _pixelWidth = 0,
      _pixelHeight = 0;

  DecodeResult._pixels(
    this._pointerAddress,
    this._releaseBudget,
    this._pixelWidth,
    this._pixelHeight, {
    required this.width,
    required this.height,
  }) : error = null;

  int? _pointerAddress;
  final int _pixelWidth;
  final int _pixelHeight;
  VoidCallback? _releaseBudget;
  bool _converting = false;
  int? get pointerAddress => _pointerAddress;
  final int width;
  final int height;
  final String? error;

  void _freeNativePixels() {
    final address = _pointerAddress;
    _pointerAddress = null;
    if (address != null) calloc.free(Pointer<Uint8>.fromAddress(address));
  }

  void _finish() {
    _freeNativePixels();
    final releaseBudget = _releaseBudget;
    _releaseBudget = null;
    releaseBudget?.call();
  }

  /// Dispose unused pixels. Once conversion begins, it owns all disposal.
  void dispose() {
    if (!_converting) _finish();
  }

  /// Transfers the pixels into an engine image. Free the isolate's buffer
  /// as soon as the engine has copied it, but hold its budget through upload.
  Future<ui.Image> consumeImage() async {
    final width = _pixelWidth;
    final height = _pixelHeight;
    final address = _pointerAddress;
    if (_converting || address == null) {
      throw StateError('Tile pixels are no longer available');
    }
    _converting = true;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(
        Pointer<Uint8>.fromAddress(address).asTypedList(width * height * 4),
      );
      _freeNativePixels();
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: width,
        height: height,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      codec = await descriptor.instantiateCodec();
      return (await codec.getNextFrame()).image;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
      _finish();
    }
  }
}

/// FFI interop interface with the native C++ library.
/// Manages loading the dynamic library and asynchronous execution
/// of decoding tasks in background Isolates.
class FfiImageDecoder {
  FfiImageDecoder() : _tileBudget = _defaultTileBudget;

  @visibleForTesting
  FfiImageDecoder.withTileBudget(this._tileBudget) : assert(_tileBudget > 0);

  static DynamicLibrary? _dylib;

  bool _isRunning = false;
  Future<void>? _startFuture;
  Isolate? _cIsolate;
  ReceivePort? _receivePort;
  SendPort? _sendPort;

  final List<_DecodeJob> _queue = [];
  // Keep ordinary pages pipelined, but a 4096×4096 tile alone can occupy
  // 64 MiB. Bound the total staging pixels even after the isolate replies.
  static const int _maxConcurrent = 3;
  static const int _defaultTileBudget = 48 * 1024 * 1024;
  final int _tileBudget;
  int _activeJobs = 0;
  int _reservedTileBytes = 0;
  int _workerGeneration = 0;

  @visibleForTesting
  int get debugReservedTileBytes => _reservedTileBytes;
  int _renderers = 0;
  bool _trimWhenIdle = false;
  bool _nativeCacheMayBeDirty = false;

  /// Retain decoded native contexts while an image view is mounted.
  /// Contexts can contain a full RGBA image even though Flutter draws tiles.
  VoidCallback retainRenderer() {
    _renderers++;
    _trimWhenIdle = false;
    var released = false;
    return () {
      if (released) return;
      released = true;
      _renderers--;
      if (_renderers != 0) return;
      _trimWhenIdle = true;
      // Let widgets replacing each other in the same frame retain the cache.
      scheduleMicrotask(_trimIdleNativeCache);
    };
  }

  void _trimIdleNativeCache() {
    final port = _sendPort;
    if (port == null ||
        !_trimWhenIdle ||
        !_nativeCacheMayBeDirty ||
        _renderers != 0 ||
        _activeJobs != 0 ||
        _queue.isNotEmpty) {
      return;
    }
    _nativeCacheMayBeDirty = false;
    port.send('clearCache');
  }

  @visibleForTesting
  Future<int> debugNativeCacheEntryCount() async {
    final port = _sendPort;
    if (port == null) return 0;
    final response = ReceivePort();
    try {
      port.send(response.sendPort);
      return await response.first as int;
    } finally {
      response.close();
    }
  }

  void cancel(Object token) {
    _queue.removeWhere((job) {
      if (job.cancelToken == token) {
        if (!job.completer.isCompleted) {
          if (job.action == 'getDimensions') {
            job.completer.complete(null);
          } else {
            job.completer.complete(DecodeResult(error: 'Cancelled'));
          }
        }
        return true;
      }
      return false;
    });
  }

  Future<void> start() {
    if (_isRunning) {
      return Future.value();
    }
    _startFuture ??= _doStart();
    return _startFuture!;
  }

  Future<void> _doStart() async {
    try {
      await _initCIsolate();
    } catch (e, stackTrace) {
      if (kDebugMode) {
        print('Error starting FFI isolate: $e');
        print(stackTrace);
      }
      await stop();
    } finally {
      _startFuture = null;
    }
  }

  Future<void> _initCIsolate() async {
    _receivePort = ReceivePort();

    _cIsolate = await Isolate.spawn(
      _cIsolateEntryPoint,
      _receivePort!.sendPort,
    );

    final completer = Completer<SendPort>();
    _receivePort!.listen((message) {
      if (message is SendPort) {
        completer.complete(message);
      }
    });

    _sendPort = await completer.future;
    _isRunning = true;
  }

  static DynamicLibrary get dylib {
    if (_dylib == null) {
      if (Platform.isAndroid) {
        _dylib = DynamicLibrary.open("libsubsampling_scale_image_view.so");
      } else if (Platform.isIOS || Platform.isMacOS) {
        try {
          _dylib = DynamicLibrary.open(
            "subsampling_scale_image_view.framework/subsampling_scale_image_view",
          );
        } catch (_) {
          _dylib = DynamicLibrary.process();
        }
      } else if (Platform.isWindows) {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        final candidates = [
          "$exeDir\\subsampling_scale_image_view.dll",
          "subsampling_scale_image_view.dll",
          "libsubsampling_scale_image_view.dll",
          "$exeDir\\libsubsampling_scale_image_view.dll",
          "${Directory.current.path}\\build\\native_assets\\windows\\subsampling_scale_image_view.dll",
          "$exeDir\\..\\..\\..\\native_assets\\windows\\subsampling_scale_image_view.dll",
        ];
        for (final path in candidates) {
          try {
            _dylib = DynamicLibrary.open(path);
            if (_dylib != null) break;
          } catch (_) {}
        }
        _dylib ??= DynamicLibrary.process();
      } else if (Platform.isLinux) {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        final candidates = [
          "$exeDir/lib/libsubsampling_scale_image_view.so",
          "$exeDir/libsubsampling_scale_image_view.so",
          "libsubsampling_scale_image_view.so",
          "${Directory.current.path}/build/native_assets/linux/libsubsampling_scale_image_view.so",
        ];
        for (final path in candidates) {
          try {
            _dylib = DynamicLibrary.open(path);
            if (_dylib != null) break;
          } catch (_) {}
        }
        _dylib ??= DynamicLibrary.process();
      } else {
        _dylib = DynamicLibrary.process();
      }
    }
    return _dylib!;
  }

  static final Pointer<Opaque> Function(
    Pointer<Utf8>,
    bool,
    Pointer<Int32>,
    Pointer<Int32>,
  )
  _initDecoder = dylib
      .lookupFunction<
        Pointer<Opaque> Function(
          Pointer<Utf8>,
          Bool,
          Pointer<Int32>,
          Pointer<Int32>,
        ),
        Pointer<Opaque> Function(
          Pointer<Utf8>,
          bool,
          Pointer<Int32>,
          Pointer<Int32>,
        )
      >('init_decoder');

  static final bool Function(
    Pointer<Opaque>,
    int,
    int,
    int,
    int,
    int,
    Pointer<Uint8>,
  )
  _decodeRegion = dylib
      .lookupFunction<
        Bool Function(
          Pointer<Opaque>,
          Int32,
          Int32,
          Int32,
          Int32,
          Int32,
          Pointer<Uint8>,
        ),
        bool Function(Pointer<Opaque>, int, int, int, int, int, Pointer<Uint8>)
      >('decode_region');

  static final void Function(Pointer<Opaque>) _freeDecoder = dylib
      .lookupFunction<
        Void Function(Pointer<Opaque>),
        void Function(Pointer<Opaque>)
      >('free_decoder');

  /// Decodes a specific region of the image asynchronously in a background Isolate.
  /// This prevents blocking the main UI thread during disk reads and decoding.
  static Future<void> _cIsolateEntryPoint(SendPort mainSendPort) async {
    final receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);

    // LRU Cache using LinkedHashMap for O(1) access, insertion, and ordering.
    // Keys are inserted in access order; to evict, remove first entry.
    final Map<String, Pointer<Opaque>> cachedContexts = {};
    final Map<String, List<int>> cachedDimensions = {};
    // lruOrder tracks insertion order; LinkedHashMap isn't directly available in isolate
    // so we use a plain Map (Dart Maps maintain insertion order since Dart 2) as O(1) ordered set.
    final Map<String, bool> lruOrder = {};
    const int maxCacheSize = 5;

    void clearCache() {
      for (final ctx in cachedContexts.values) {
        if (ctx.address != 0) {
          _freeDecoder(ctx);
        }
      }
      cachedContexts.clear();
      lruOrder.clear();
      cachedDimensions.clear();
    }

    receivePort.listen((message) async {
      if (message is Map<String, dynamic>) {
        final responsePort = message['responsePort'] as SendPort;
        final action = message['action'] as String?;
        final paramsJson = message['params'];
        if (paramsJson is! Map<String, dynamic>) {
          responsePort.send(<String, dynamic>{
            'success': false,
            'error': 'Invalid decode params',
          });
          return;
        }
        final params = DecodeParams.fromJson(paramsJson);

        final key = "${params.filePath}_${params.cropBorders}";
        Pointer<Opaque> ctx = cachedContexts[key] ?? Pointer.fromAddress(0);
        int imgWidth = 0;
        int imgHeight = 0;

        if (ctx.address == 0) {
          // LRU Eviction: O(1) — remove first (oldest) entry from ordered map
          if (cachedContexts.length >= maxCacheSize) {
            final oldestKey = lruOrder.keys.first;
            lruOrder.remove(oldestKey);
            final oldestCtx = cachedContexts.remove(oldestKey);
            cachedDimensions.remove(oldestKey);
            if (oldestCtx != null && oldestCtx.address != 0) {
              _freeDecoder(oldestCtx);
            }
          }

          final Pointer<Utf8> pathPtr = params.filePath.toNativeUtf8();
          final Pointer<Int32> wPtr = calloc<Int32>();
          final Pointer<Int32> hPtr = calloc<Int32>();
          try {
            final Pointer<Opaque> newCtx = _initDecoder(
              pathPtr,
              params.cropBorders,
              wPtr,
              hPtr,
            );
            if (newCtx.address == 0) {
              responsePort.send({
                'success': false,
                'error':
                    "Failed to initialize decoder for file: ${params.filePath}",
              });
              return;
            }
            ctx = newCtx;
            cachedContexts[key] = ctx;
            lruOrder[key] = true; // O(1) insertion at end
            imgWidth = wPtr.value;
            imgHeight = hPtr.value;
            cachedDimensions[key] = [imgWidth, imgHeight];
          } catch (e) {
            responsePort.send({
              'success': false,
              'error': "Error initializing FFI decoder: $e",
            });
            return;
          } finally {
            calloc.free(pathPtr);
            calloc.free(wPtr);
            calloc.free(hPtr);
          }
        } else {
          // Update LRU order: O(1) — remove and re-insert at end
          lruOrder.remove(key);
          lruOrder[key] = true;
          final dims = cachedDimensions[key]!;
          imgWidth = dims[0];
          imgHeight = dims[1];
        }

        if (action == 'getDimensions') {
          responsePort.send({
            'success': true,
            'width': imgWidth,
            'height': imgHeight,
          });
          return;
        }

        // Calculates required size for destination pixel buffer (RGBA)
        final int rectWidth = params.right - params.left;
        final int rectHeight = params.bottom - params.top;
        final int destWidth = rectWidth ~/ params.sampleSize;
        final int destHeight = rectHeight ~/ params.sampleSize;
        final int bufferSize = destWidth * destHeight * 4;

        final Pointer<Uint8> rgbaBuffer = calloc<Uint8>(bufferSize);

        try {
          final bool success = _decodeRegion(
            ctx,
            params.left,
            params.top,
            params.right,
            params.bottom,
            params.sampleSize,
            rgbaBuffer,
          );

          if (!success) {
            calloc.free(rgbaBuffer);
            responsePort.send({'error': "Region decoding failed."});
            return;
          }

          responsePort.send({
            'success': true,
            'pointerAddress': rgbaBuffer.address,
            'width': imgWidth,
            'height': imgHeight,
          });
        } catch (e) {
          calloc.free(rgbaBuffer);
          responsePort.send({'success': false, 'error': "FFI error: $e"});
        }
      } else if (message == 'clearCache' || message == 'dispose') {
        clearCache();
        if (message == 'dispose') receivePort.close();
      } else if (message is SendPort) {
        message.send(cachedContexts.length);
      }
    });
  }

  Future<DecodeResult?> decodeRegionAsync(
    DecodeParams params, {
    Object? cancelToken,
  }) async {
    if (params.sampleSize <= 0 ||
        params.pixelWidth <= 0 ||
        params.pixelHeight <= 0) {
      return DecodeResult(error: 'Invalid tile size');
    }
    await start();
    if (_sendPort == null) {
      if (kDebugMode) {
        print('FfiImageDecoder isolate is not running');
      }
      return null;
    }

    final completer = Completer<DecodeResult?>();
    final job = _DecodeJob(
      params: params,
      completer: completer,
      cancelToken: cancelToken,
    );

    _queue.add(job);
    _processNext();

    return completer.future;
  }

  Future<List<int>?> getImageDimensionsAsync(
    String filePath, {
    bool cropBorders = false,
    Object? cancelToken,
  }) async {
    await start();
    if (_sendPort == null) {
      if (kDebugMode) {
        print('FfiImageDecoder isolate is not running');
      }
      return null;
    }

    final completer = Completer<List<int>?>();
    final job = _DecodeJob(
      params: DecodeParams(
        filePath: filePath,
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
        sampleSize: 1,
        cropBorders: cropBorders,
      ),
      completer: completer,
      cancelToken: cancelToken,
      action: 'getDimensions',
    );

    _queue.add(job);
    _processNext();

    return completer.future;
  }

  void _processNext() {
    // Sort once before dispatching, not per iteration.
    // Priority: getDimensions first, then high sampleSize (base layer), LIFO within.
    if (_queue.length > 1) {
      _queue.sort((a, b) {
        final aPriority = a.action == 'getDimensions'
            ? 1000
            : a.params.sampleSize;
        final bPriority = b.action == 'getDimensions'
            ? 1000
            : b.params.sampleSize;
        return bPriority.compareTo(
          aPriority,
        ); // descending: highest priority last for removeLast
      });
    }

    while (_activeJobs < _maxConcurrent && _queue.isNotEmpty) {
      var next = _queue.length - 1;
      bool fits(int bytes) =>
          bytes == 0 ||
          _reservedTileBytes == 0 ||
          bytes <= _tileBudget - _reservedTileBytes;
      if (!fits(_queue[next].pixelBytes)) {
        // A single oversized tile may run alone. While waiting for its
        // budget, dimension-only requests can still reserve page layout.
        next = _queue.lastIndexWhere((job) => job.action == 'getDimensions');
        if (next < 0) break;
      }
      final job = _queue.removeAt(next);
      final bytes = job.pixelBytes;
      final generation = _workerGeneration;
      _reservedTileBytes += bytes;
      _activeJobs++;
      _nativeCacheMayBeDirty = true;

      final responsePort = ReceivePort();
      responsePort.listen((response) {
        responsePort.close();
        final current = generation == _workerGeneration;
        if (current) _activeJobs--;
        var transferred = false;
        if (response is Map<String, dynamic> && response['success'] == true) {
          if (job.action == 'getDimensions') {
            job.completer.complete(
              current
                  ? [response['width'] as int, response['height'] as int]
                  : null,
            );
          } else {
            final pointerAddress = response['pointerAddress'] as int?;
            if (current && pointerAddress != null) {
              transferred = true;
              job.completer.complete(
                DecodeResult._pixels(
                  pointerAddress,
                  () {
                    if (generation != _workerGeneration) return;
                    _reservedTileBytes -= bytes;
                    _processNext();
                  },
                  job.params.pixelWidth,
                  job.params.pixelHeight,
                  width: response['width'] as int,
                  height: response['height'] as int,
                ),
              );
            } else {
              if (pointerAddress != null) {
                calloc.free(Pointer<Uint8>.fromAddress(pointerAddress));
              }
              job.completer.complete(null);
            }
          }
        } else if (response is Map<String, dynamic>) {
          if (kDebugMode && current) {
            debugPrint('Image job failed: ${response['error']}');
          }
          if (job.action == 'getDimensions' || !current) {
            job.completer.complete(null);
          } else {
            job.completer.complete(
              DecodeResult(error: response['error'] as String?),
            );
          }
        } else {
          job.completer.complete(null);
        }

        if (!current) return;
        if (!transferred) _reservedTileBytes -= bytes;
        _processNext();
      });

      _sendPort!.send({
        'action': job.action,
        'params': job.params.toJson(),
        'responsePort': responsePort.sendPort,
      });
    }
    _trimIdleNativeCache();
  }

  bool getImageDimensions(
    String filePath,
    List<int> outSize, {
    bool cropBorders = false,
  }) {
    final Pointer<Utf8> pathPtr = filePath.toNativeUtf8();
    final Pointer<Int32> wPtr = calloc<Int32>();
    final Pointer<Int32> hPtr = calloc<Int32>();

    try {
      final Pointer<Opaque> ctx = _initDecoder(
        pathPtr,
        cropBorders,
        wPtr,
        hPtr,
      );
      if (ctx.address == 0) return false;

      outSize[0] = wPtr.value;
      outSize[1] = hPtr.value;
      _freeDecoder(ctx);
      return true;
    } catch (_) {
      return false;
    } finally {
      calloc.free(pathPtr);
      calloc.free(wPtr);
      calloc.free(hPtr);
    }
  }

  Future<void> stop() async {
    _startFuture = null;
    if (!_isRunning && _cIsolate == null && _receivePort == null) {
      return;
    }

    try {
      _sendPort?.send('dispose');
    } catch (_) {}
    _cIsolate?.kill(priority: Isolate.immediate);
    _receivePort?.close();
    _sendPort = null;
    _cIsolate = null;
    _receivePort = null;
    _isRunning = false;
    _workerGeneration++;
    _activeJobs = 0;
    _reservedTileBytes = 0;
    _nativeCacheMayBeDirty = false;

    for (final job in _queue) {
      if (!job.completer.isCompleted) {
        if (job.action == 'getDimensions') {
          job.completer.complete(null);
        } else {
          job.completer.complete(DecodeResult(error: 'Cancelled'));
        }
      }
    }
    _queue.clear();
  }
}

class _DecodeJob {
  final DecodeParams params;
  final Completer<dynamic> completer;
  final Object? cancelToken;
  final String? action;

  int get pixelBytes => action == 'getDimensions' ? 0 : params.pixelBytes;

  _DecodeJob({
    required this.params,
    required this.completer,
    this.cancelToken,
    this.action,
  });
}

final ffiImageDecoder = FfiImageDecoder();
