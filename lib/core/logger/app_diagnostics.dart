import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

final appDiagnostics = AppDiagnostics();

/// Opt-in, bounded local diagnostics. Callers never wait for record/file I/O.
/// Only fixed event/token names and scalar measurements cross this boundary.
class AppDiagnostics {
  AppDiagnostics({
    Future<Directory> Function()? directoryProvider,
    Future<Directory> Function()? exportDirectoryProvider,
    this.maxBytes = 2 * 1024 * 1024,
    this.maxFiles = 3,
    this.maxPending = 256,
    this.flushInterval = const Duration(milliseconds: 250),
    DateTime Function()? now,
  }) : assert(maxBytes >= 256),
       assert(maxFiles > 0),
       assert(maxPending > 0),
       _directoryProvider = directoryProvider ?? _defaultDirectory,
       _exportDirectoryProvider =
           exportDirectoryProvider ?? _defaultExportDirectory,
       _now = now ?? DateTime.now;

  final Future<Directory> Function() _directoryProvider;
  final Future<Directory> Function() _exportDirectoryProvider;
  final DateTime Function() _now;
  final int maxBytes, maxFiles, maxPending;
  final Duration flushInterval;
  final Queue<List<int>> _pending = Queue<List<int>>();
  final Set<String> _recent = <String>{};
  final String _session = '${DateTime.now().microsecondsSinceEpoch}-$pid';
  final Stopwatch _elapsed = Stopwatch()..start();
  Future<void> _tail = Future<void>.value();
  Future<void>? _flushing;
  Timer? _timer;
  bool _enabled = false;
  Object? _lastError;
  int _sequence = 0, _dropped = 0, _epoch = 0, _burstCount = 0;
  int? _burstSecond;

  bool get enabled => _enabled;
  Object? get lastError => _lastError;

  static Future<Directory> _defaultDirectory() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/app_logs');

  static Future<Directory> _defaultExportDirectory() async =>
      Directory('${(await getTemporaryDirectory()).path}/app-diagnostics');

  /// Persistence of the preference belongs to the settings repository.
  /// Disabling stops new capture immediately and keeps existing files.
  Future<void> setEnabled(bool value) async {
    final epoch = ++_epoch;
    if (_enabled && !value) record('logging.disabled');
    _enabled = false;
    if (!value) {
      // Turning capture off must stay responsive even if storage is stalled.
      unawaited(flush());
      return;
    }
    await flush();
    _recent.clear();
    _burstSecond = null;
    _burstCount = 0;
    if (!value || epoch != _epoch) return;
    try {
      final folder = await directory();
      final probe = File(
        '${folder.path}/.app-diagnostics-probe-$_session-$epoch',
      );
      await _regularOrMissing(probe);
      await probe.writeAsString('');
      await probe.delete();
      if (epoch != _epoch) return;
      _lastError = null;
      _enabled = true;
      record('logging.enabled');
    } catch (error) {
      _lastError = _errorType(error);
      rethrow;
    }
  }

  void record(String event, {Map<String, Object?> fields = const {}}) {
    if (!_enabled || event.length > 64 || !_events.contains(event)) return;
    try {
      _enqueue(event, _sanitize(fields));
    } catch (error) {
      // Diagnostics cannot change an app operation's success/failure.
      _lastError = _errorType(error);
    }
  }

  void recordError(
    String event,
    Object error,
    StackTrace? stack, {
    Map<String, Object?> fields = const {},
  }) {
    if (!_enabled || event.length > 64 || !_events.contains(event)) return;
    try {
      _enqueue(event, {
        ..._sanitize(fields),
        'errorType': _errorType(error),
        if (stack != null) 'stack': _safeStack(stack),
      });
    } catch (failure) {
      _lastError = _errorType(failure);
    }
  }

  void _enqueue(String event, Map<String, Object?> fields) {
    final now = _now().toUtc();
    final second = now.millisecondsSinceEpoch ~/ 1000;
    if (_burstSecond != second) {
      _burstSecond = second;
      _burstCount = 0;
      _recent.clear();
    }
    // Check capacity before encoding; memory and work remain bounded in bursts.
    if (_pending.length >= maxPending || _burstCount >= 64) {
      _dropped++;
      _schedule();
      return;
    }
    // Count rejected oversized attempts too, keeping the dedup set bounded.
    _burstCount++;
    final signature = jsonEncode({'event': event, ...fields});
    if (!_recent.add(signature)) {
      _dropped++;
      _schedule();
      return;
    }
    final bytes = _encode(event, fields, now);
    if (bytes.length > maxBytes || bytes.length > 4096) {
      _dropped++;
      _schedule();
      return;
    }
    _pending.add(bytes);
    _schedule();
  }

  List<int> _encode(
    String event,
    Map<String, Object?> fields,
    DateTime now,
  ) => utf8.encode(
    '${jsonEncode({'time': now.toIso8601String(), 'session': _session, 'sessionElapsedMs': _elapsed.elapsedMilliseconds, 'sequence': ++_sequence, 'event': event, ...fields})}\n',
  );

  void _schedule() {
    if (_flushing != null) return;
    _timer ??= Timer(flushInterval, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// Drains the currently captured batch, swallowing disk failures.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    if (_flushing != null) return _flushing!;
    // Repeated flushes share one writer even when storage is stalled.
    _tail = _tail.then((_) async {
      try {
        while (_pending.isNotEmpty || _dropped > 0) {
          final batch = <List<int>>[];
          while (_pending.isNotEmpty) {
            batch.add(_pending.removeFirst());
          }
          if (_dropped > 0) {
            batch.add(
              _encode('logging.dropped', {
                'droppedEvents': _dropped,
              }, _now().toUtc()),
            );
            _dropped = 0;
          }
          final folder = await directory();
          final active = _file(folder, 0);
          var length = await _regularOrMissing(active)
              ? await active.length()
              : 0;
          final buffer = BytesBuilder(copy: false);
          Future<void> writeBuffer() async {
            if (buffer.isEmpty) return;
            await active.writeAsBytes(
              buffer.takeBytes(),
              mode: FileMode.append,
            );
          }

          for (final bytes in batch) {
            if (length + bytes.length > maxBytes) {
              await writeBuffer();
              await _rotate(folder);
              length = 0;
            }
            buffer.add(bytes);
            length += bytes.length;
          }
          await writeBuffer();
          _lastError = null;
        }
      } catch (error) {
        _lastError = _errorType(error);
      }
    });
    final current = _tail;
    _flushing = current;
    unawaited(
      current.then((_) {
        _flushing = null;
        if (_pending.isNotEmpty || _dropped > 0) _schedule();
      }),
    );
    return current;
  }

  Future<Directory> directory() async {
    final folder = await _directoryProvider();
    await _prepareDirectory(folder);
    return folder;
  }

  static Future<void> _prepareDirectory(Directory folder) async {
    final type = await FileSystemEntity.type(folder.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const FileSystemException('Diagnostic directory is not regular');
    }
    await folder.create(recursive: true);
  }

  static Future<bool> _regularOrMissing(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file) {
      throw const FileSystemException('Diagnostic file is not regular');
    }
    return true;
  }

  File _file(Directory folder, int index) => File(
    '${folder.path}/app-diagnostics${index == 0 ? '' : '.$index'}.jsonl',
  );

  Future<void> _rotate(Directory folder) async {
    for (var index = maxFiles - 1; index >= 0; index--) {
      final source = _file(folder, index);
      if (!await _regularOrMissing(source)) continue;
      if (index == maxFiles - 1) {
        await source.delete();
      } else {
        final target = _file(folder, index + 1);
        await _regularOrMissing(target);
        await source.rename(target.path);
      }
    }
  }

  /// Exact owned filenames only, newest first. Download/provider logs stay out.
  Future<List<File>> listFiles() async {
    final folder = await directory();
    final files = <File>[];
    for (var index = 0; index < maxFiles; index++) {
      final file = _file(folder, index);
      if (await _regularOrMissing(file)) files.add(file);
    }
    return files;
  }

  /// Makes a bounded local export; sharing is always a separate user action.
  Future<File> export() async {
    await flush();
    final completer = Completer<File>();
    _tail = _tail.then((_) async {
      try {
        final folder = await _exportDirectoryProvider();
        await _prepareDirectory(folder);
        final exported = File('${folder.path}/app-diagnostics.jsonl');
        await _regularOrMissing(exported);
        final output = BytesBuilder(copy: false);
        for (final file in (await listFiles()).reversed) {
          final handle = await file.open();
          try {
            final length = await handle.length();
            final offset = length > maxBytes ? length - maxBytes : 0;
            await handle.setPosition(offset);
            final bytes = await handle.read(maxBytes);
            // If an externally oversized file was trimmed, omit its partial row.
            final start = offset == 0 ? 0 : bytes.indexOf(10) + 1;
            if (start > 0 || offset == 0) output.add(bytes.sublist(start));
          } finally {
            await handle.close();
          }
        }
        await exported.writeAsBytes(output.takeBytes());
        completer.complete(exported);
      } catch (error, stack) {
        _lastError = _errorType(error);
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  static Map<String, Object?> _sanitize(Map<String, Object?> fields) {
    final safe = <String, Object?>{};
    // Iterate fixed keys, never the caller's potentially huge map/collections.
    for (final key in _scalarKeys) {
      final value = fields[key];
      if (value is num &&
          _numericKeys.contains(key) &&
          value.isFinite &&
          value.abs() <= 1000000000000000) {
        safe[key] = value;
      } else if (value is bool && _booleanKeys.contains(key)) {
        safe[key] = value;
      } else if (value is String &&
          _tokenKeys.contains(key) &&
          value.length <= 48 &&
          _tokens.contains(value)) {
        safe[key] = value;
      }
    }
    return safe;
  }

  static String _errorType(Object error) {
    final type = error.runtimeType.toString();
    return _errorTypes.contains(type) ? type : 'UnknownError';
  }

  static List<String> _safeStack(StackTrace stack) {
    final raw = stack.toString();
    final bounded = raw.substring(0, raw.length > 8192 ? 8192 : raw.length);
    final frames = <String>[];
    for (final line in bounded.split('\n').take(48)) {
      final opening = line.lastIndexOf('(');
      final uri = opening >= 0 && line.endsWith(')')
          ? line.substring(opening + 1, line.length - 1)
          : line.trim();
      if (uri.length > 180) continue;
      final own = _appFrame.firstMatch(uri);
      if (own != null) {
        frames.add(uri);
      } else {
        final other = _packageFrame.firstMatch(uri);
        if (other != null && _packages.contains(other[1])) {
          frames.add('package:${other[1]}:${other[2]}:${other[3] ?? '0'}');
        } else {
          final dart = _dartFrame.firstMatch(uri);
          if (dart != null && _dartLibraries.contains(dart[1])) {
            frames.add('dart:${dart[1]}:${dart[2]}:${dart[3] ?? '0'}');
          }
        }
      }
      if (frames.length == 12) break;
    }
    return frames;
  }

  static final _appFrame = RegExp(
    r'^package:animewitcher/(?:[a-zA-Z0-9_]+/)*[a-zA-Z0-9_]+\.dart:[0-9]{1,7}(?::[0-9]{1,7})?$',
  );
  static final _packageFrame = RegExp(
    r'^package:([a-z_][a-z0-9_]*)/(?:[a-zA-Z0-9_]+/)*[a-zA-Z0-9_]+\.dart:([0-9]{1,7})(?::([0-9]{1,7}))?$',
  );
  static final _dartFrame = RegExp(
    r'^dart:([a-z_]+)(?:/[a-zA-Z0-9_]+\.dart)?:([0-9]{1,7})(?::([0-9]{1,7}))?$',
  );
  static const _packages = {
    'flutter',
    'dio',
    'http',
    'go_router',
    'riverpod',
    'flutter_riverpod',
    'hooks_riverpod',
    'media_kit',
    'video_view',
    'background_downloader',
    'path_provider',
    'shared_preferences',
    'hive',
    'hive_flutter',
  };
  static const _dartLibraries = {
    'async',
    'core',
    'io',
    'convert',
    'isolate',
    'ui',
    '_internal',
  };
  static const _errorTypes = {
    'Exception',
    'Error',
    'StateError',
    'ArgumentError',
    'RangeError',
    'TypeError',
    '_TypeError',
    'FormatException',
    'TimeoutException',
    'SocketException',
    'FileSystemException',
    'HttpException',
    'HandshakeException',
    'DioException',
    'FlutterError',
    'PlatformException',
    'MissingPluginException',
    'UnsupportedError',
    'AssertionError',
    '_AssertionError',
    'LateInitializationError',
    'UnknownError',
    'AnimeWitcherAccountException',
    'AnimeWitcherSearchDisabledException',
    'LibrarySignInRequiredException',
    'Anime4kDownloadException',
    'LocalVideoPayloadProblem',
  };
  static const _numericKeys = {
    'count',
    'attempt',
    'elapsedMs',
    'durationMs',
    'duration_ms',
    'httpStatus',
    'status',
    'bytes',
    'totalBytes',
    'progress',
    'completed',
    'total',
    'completedPages',
    'totalPages',
    'generation',
    'sourceSessionId',
    'requestId',
    'request_id',
    'positionMs',
    'version_major',
    'version_minor',
    'version_patch',
    'build',
  };
  static const _booleanKeys = {
    'enabled',
    'active',
    'success',
    'cancelled',
    'fromCache',
    'local',
    'buffering',
  };
  static const _tokenKeys = {
    'area',
    'operation',
    'status',
    'phase',
    'reason',
    'result',
    'errorType',
    'error_type',
    'method',
    'screen',
    'state',
    'route',
    'provider',
    'engine',
    'kind',
    'platform',
    'build_mode',
  };
  static final _scalarKeys = {..._numericKeys, ..._booleanKeys, ..._tokenKeys};
  static const _tokens = {
    ..._errorTypes,
    'binding_ready',
    'backdrop_ready',
    'media_ready',
    'window_ready',
    'storage_ready',
    'artwork_ready',
    'app_ready',
    'begin',
    'end',
    'error',
    'resumed',
    'inactive',
    'hidden',
    'paused',
    'detached',
    'home',
    'search',
    'library',
    'downloads',
    'settings',
    'manga',
    'details',
    'manga_details',
    'manga_reader',
    'player',
    'view_all',
    'other',
    'riverpod',
    'shared_http',
    'account_http',
    'anizip_http',
    'subtitle_http',
    'GET',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
    'HEAD',
    'OPTIONS',
    'OTHER',
    'connectionTimeout',
    'sendTimeout',
    'receiveTimeout',
    'badCertificate',
    'badResponse',
    'cancel',
    'connectionError',
    'unknown',
    'idle',
    'bootstrapping',
    'fetchingSources',
    'checkingSources',
    'openingSource',
    'switchingEngine',
    'bufferingInitial',
    'bufferingRuntime',
    'switchingSource',
    'reconnectingLive',
    'loadingNextEpisode',
    'media_kit',
    'video_view',
    'background',
    'foreground',
    'readiness',
    'open',
    'resume',
    'reconnect',
    'stop',
    'dispose',
    'source_replaced',
    'startup_timeout',
    'success',
    'skipped',
    'offline',
    'stale',
    'pending',
    'queued',
    'running',
    'held',
    'complete',
    'failed',
    'canceled',
    'missing',
    'sourceExpired',
    'transport',
    'filesystem',
    'integrity',
    'valid',
    'empty',
    'sizeMismatch',
    'invalid',
    'gatewayInitialize',
    'gatewayRehydrate',
    'recovery',
    'hit',
    'episode',
    'poster',
    'lookup',
    'probe',
    'dispatch',
    'start',
    'android',
    'ios',
    'macos',
    'windows',
    'linux',
    'fuchsia',
    'debug',
    'profile',
    'release',
  };
  static const _events = {
    'logging.enabled',
    'logging.disabled',
    'startup_phase',
    'startup_error',
    'app_metadata',
    'flutter_error',
    'platform_error',
    'lifecycle',
    'navigation',
    'provider_error',
    'service_error',
    'network_start',
    'network_finish',
    'network_error',
    'download.state',
    'download.integrity',
    'download.init',
    'artwork.capture',
    'artwork.lookup',
    'proxy.lifecycle',
    'proxy.error',
    'player.start',
    'player.source_session',
    'player.phase',
    'player.local_resolve.begin',
    'player.local_resolve.end',
    'player.local_resolve.error',
    'player.properties.begin',
    'player.properties.end',
    'player.properties.error',
    'player.native_ready.begin',
    'player.native_ready.end',
    'player.native_ready.error',
    'player.renderer_ready.begin',
    'player.renderer_ready.end',
    'player.renderer_ready.error',
    'player.engine_open.begin',
    'player.engine_open.end',
    'player.engine_open.error',
    'player.first_position',
    'player.resume_seek.begin',
    'player.resume_seek.end',
    'player.resume_seek.error',
    'player.reconnect.begin',
    'player.reconnect.end',
    'player.reconnect.error',
    'player.network_restored',
    'player.lifecycle',
    'player.route_exit.begin',
    'player.route_exit.end',
    'player.startup_timeout',
    'player.teardown_stop.begin',
    'player.teardown_stop.end',
    'player.teardown_stop.timeout',
    'player.teardown_stop.error',
    'player.teardown_dispose.begin',
    'player.teardown_dispose.end',
    'player.teardown_dispose.error',
    'player.session_stale',
  };
}
