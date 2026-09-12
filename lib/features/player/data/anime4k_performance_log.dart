import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'anime4k.dart';
import 'anime4k_performance.dart';

typedef Anime4kDocumentsDirectoryResolver = Future<Directory> Function();
typedef Anime4kDeviceInfoResolver = Future<Map<String, Object?>> Function();
typedef Anime4kClock = DateTime Function();

/// Device-local JSONL benchmark log for the Apple Anime4K performance work.
///
/// Nothing is uploaded. A new `anime4k-*` file is created under Documents/log
/// for each service lifetime so a physical-device preview run can be inspected
/// from the settings UI and attached to benchmark evidence later.
class Anime4kPerformanceLog {
  Anime4kPerformanceLog({
    Anime4kDocumentsDirectoryResolver? documentsDirectory,
    Anime4kDeviceInfoResolver? deviceInfo,
    Anime4kClock? now,
  }) : _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory,
       _deviceInfo = deviceInfo ?? _readDeviceInfo,
       _now = now ?? DateTime.now;

  final Anime4kDocumentsDirectoryResolver _documentsDirectory;
  final Anime4kDeviceInfoResolver _deviceInfo;
  final Anime4kClock _now;

  Future<File>? _sessionFile;
  Future<void> _writeTail = Future<void>.value();

  Future<void> recordRoute({
    required Anime4kBackend backend,
    required Anime4kMode mode,
    required Anime4kQuality requestedQuality,
    required bool ecoEnabled,
    required bool metalFxExperiment,
    String? colorSignal,
    String? reason,
  }) {
    return _append(<String, Object?>{
      'type': 'route',
      'backend': backend.name,
      'mode': mode.name,
      'requestedQuality': requestedQuality.name,
      'ecoEnabled': ecoEnabled,
      'colorSignal': colorSignal,
      'reason': reason,
      'metalFxExperiment': metalFxExperiment,
    });
  }

  Future<void> recordSnapshot(
    Anime4kPerformanceSnapshot snapshot, {
    required bool metalFxExperiment,
  }) {
    return _append(<String, Object?>{
      'type': 'snapshot',
      'backend': snapshot.backend.name,
      'requestedMode': snapshot.requestedMode.name,
      'requestedQuality': snapshot.requestedQuality.name,
      'effectiveQuality': snapshot.effectiveQuality.name,
      'inputWidth': snapshot.inputWidth,
      'inputHeight': snapshot.inputHeight,
      'processingWidth': snapshot.processingWidth,
      'processingHeight': snapshot.processingHeight,
      'averageFrameTimeMs': snapshot.averageFrameTimeMs,
      'p95FrameTimeMs': snapshot.p95FrameTimeMs,
      'processedFrames': snapshot.processedFrames,
      'skippedDuplicateFrames': snapshot.skippedDuplicateFrames,
      'droppedOrLateFrames': snapshot.droppedOrLateFrames,
      'thermalLevel': snapshot.thermalLevel.name,
      'lowPowerMode': snapshot.lowPowerMode,
      'metalFxExperiment': metalFxExperiment,
    });
  }

  /// Returns the newest Anime4K log, including logs from a previous app run.
  Future<File?> latestLogFile() async {
    final root = await _documentsDirectory();
    final directory = Directory(p.join(root.path, 'log'));
    if (!await directory.exists()) return null;

    final files = await directory
        .list(followLinks: false)
        .where((entity) {
          return entity is File &&
              p.basename(entity.path).startsWith('anime4k-') &&
              p.extension(entity.path) == '.log';
        })
        .cast<File>()
        .toList();
    if (files.isEmpty) return null;
    files.sort((a, b) => b.path.compareTo(a.path));
    return files.first;
  }

  Future<String?> latestLogPath() async => (await latestLogFile())?.path;

  /// Reads only the tail so a long playback session cannot make the settings
  /// dialog allocate an unbounded string.
  Future<String?> readLatest({int maxBytes = 256 * 1024}) async {
    final file = await latestLogFile();
    if (file == null) return null;
    final length = await file.length();
    final start = length > maxBytes ? length - maxBytes : 0;
    final bytes = await file.openRead(start).fold<BytesBuilder>(
      BytesBuilder(copy: false),
      (builder, data) => builder..add(data),
    );
    final text = utf8.decode(bytes.takeBytes(), allowMalformed: true);
    return start == 0 ? text : '[... earlier Anime4K log omitted ...]\n$text';
  }

  Future<void> _append(Map<String, Object?> event) {
    final next = _appendAfter(_writeTail, event);
    _writeTail = next;
    return next;
  }

  Future<void> _appendAfter(
    Future<void> previous,
    Map<String, Object?> event,
  ) async {
    try {
      await previous;
    } catch (_) {
      // A logging failure must never poison the next sample or playback.
    }

    try {
      final file = await _ensureSessionFile();
      final entry = <String, Object?>{
        'timestamp': _now().toUtc().toIso8601String(),
        ...event,
      };
      await file.writeAsString(
        '${jsonEncode(entry)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Anime4K performance log write skipped: $error');
      }
    }
  }

  Future<File> _ensureSessionFile() {
    return _sessionFile ??= _createSessionFile();
  }

  Future<File> _createSessionFile() async {
    final root = await _documentsDirectory();
    final directory = Directory(p.join(root.path, 'log'));
    await directory.create(recursive: true);
    final stamp = _now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final file = File(p.join(directory.path, 'anime4k-$stamp.log'));
    final device = await _deviceInfo();
    await file.writeAsString(
      '${jsonEncode(<String, Object?>{
        'timestamp': _now().toUtc().toIso8601String(),
        'type': 'session',
        ...device,
      })}\n',
      mode: FileMode.append,
      flush: true,
    );
    return file;
  }

  static Future<Map<String, Object?>> _readDeviceInfo() async {
    final info = await DeviceInfoPlugin().deviceInfo;
    final data = info.data;
    final nestedUtsname = data['utsname'];
    String? machine;
    if (nestedUtsname is Map) {
      final value = nestedUtsname['machine'];
      if (value != null) machine = '$value';
    }
    machine ??= _firstText(data, const <String>['machine', 'arch']);

    final physicalValue = data['isPhysicalDevice'];
    final isPhysicalDevice = physicalValue is bool ? physicalValue : true;
    return <String, Object?>{
      'platform': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'deviceModel': _firstText(
        data,
        const <String>['modelName', 'model', 'productName', 'computerName'],
      ),
      'machine': machine,
      'isPhysicalDevice': isPhysicalDevice,
    };
  }

  static String? _firstText(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key];
      if (value == null) continue;
      final text = '$value'.trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }
}

final anime4kPerformanceLogProvider = Provider<Anime4kPerformanceLog>((ref) {
  return Anime4kPerformanceLog();
});
