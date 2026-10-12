import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'download_continued_processing_v2.dart';
import 'download_v2_models.dart';
import 'manga_chapter_manifest_v2.dart';

enum DownloadArtworkKindV2 { episode, poster }

/// One private copy per logical download avoids a shared-poster deletion race.
/// This storage has no image-cache TTL and never owns the downloaded video.
final class DownloadArtworkStoreV2 {
  DownloadArtworkStoreV2({
    Future<Directory> Function()? supportDirectory,
    Future<File?> Function(String)? cachedFileForUrl,
    Future<List<int>?> Function(Uri)? fetchBytes,
    Future<void> Function(File temporary, String targetPath)? publishFile,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _cachedFileForUrl = cachedFileForUrl ?? _cachedFile,
       _fetchBytes = fetchBytes ?? _fetchImage,
       _publishFile = publishFile ?? ((file, path) async { await file.rename(path); });

  static const int _maxBytes = 10 * 1024 * 1024;
  static const Duration _fetchTimeout = Duration(seconds: 20);
  final Future<Directory> Function() _supportDirectory;
  final Future<File?> Function(String) _cachedFileForUrl;
  final Future<List<int>?> Function(Uri) _fetchBytes;
  final Future<void> Function(File, String) _publishFile;
  final Map<String, int> _deletionEpochs = <String, int>{};
  final Map<String, _ArtworkWriteV2> _writes = <String, _ArtworkWriteV2>{};
  int _temporarySequence = 0;

  int _epochFor(String logicalId) => _deletionEpochs[logicalId] ?? 0;

  Future<Directory> _support() async {
    final directory = await _supportDirectory().timeout(_fetchTimeout);
    await directory.create(recursive: true);
    return Directory(await directory.resolveSymbolicLinks());
  }

  Future<Directory?> _childDirectory(
    Directory parent,
    String leaf, {
    bool create = false,
  }) async {
    final directory = Directory(p.join(parent.path, leaf));
    var type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound && create) {
      await directory.create();
      type = await FileSystemEntity.type(directory.path, followLinks: false);
    }
    if (type != FileSystemEntityType.directory ||
        !p.equals(await directory.resolveSymbolicLinks(), directory.path)) {
      return null;
    }
    return directory;
  }

  Future<Directory?> _ownedDirectory(String logicalId, {bool create = false}) async {
    if (kIsWeb || logicalId.trim().isEmpty) return null;
    final support = await _support();
    final root = await _childDirectory(support, 'download_artwork_v2', create: create);
    if (root == null) return null;
    return _childDirectory(root, sha256.convert(utf8.encode(logicalId)).toString(), create: create);
  }

  Future<File?> legacyFileFor(String taskId) async {
    if (kIsWeb || taskId.trim().isEmpty) return null;
    try {
      final support = await _support();
      final directory = Directory(p.join(support.path, 'download_episode_artwork'));
      final type = await FileSystemEntity.type(directory.path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          (type != FileSystemEntityType.directory ||
              !p.equals(await directory.resolveSymbolicLinks(), directory.path))) {
        return null;
      }
      final key = sha1.convert(taskId.codeUnits).toString();
      return File(p.join(directory.path, '$key.img'));
    } catch (_) {
      return null;
    }
  }

  Future<bool> _validImage(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) return false;
    final length = await file.length();
    return length > 0 && length <= _maxBytes && await isMangaPageImageV2(file);
  }

  Future<File?> existingLegacy(String taskId) async {
    try {
      final file = await legacyFileFor(taskId);
      return file != null && await _validImage(file) ? file : null;
    } catch (_) {
      return null;
    }
  }

  Future<File?> existing(String logicalId, DownloadArtworkKindV2 kind) async {
    try {
      final directory = await _ownedDirectory(logicalId);
      if (directory == null) return null;
      final file = File(p.join(directory.path, '${kind.name}.img'));
      return await _validImage(file) ? file : null;
    } catch (_) {
      return null;
    }
  }

  Future<File?> ensure({
    required String logicalId,
    required DownloadArtworkKindV2 kind,
    String? url,
    String? legacyTaskId,
  }) => _ensure(
    logicalId: logicalId, kind: kind, url: url, legacyTaskId: legacyTaskId,
    epoch: _epochFor(logicalId), alive: () => true,
  );

  Future<File?> _ensure({
    required String logicalId,
    required DownloadArtworkKindV2 kind,
    required int epoch,
    required bool Function() alive,
    String? url,
    String? legacyTaskId,
  }) async {
    bool allowed() => alive() && _epochFor(logicalId) == epoch;
    if (kIsWeb || logicalId.trim().isEmpty || !allowed()) return null;
    final saved = await existing(logicalId, kind);
    if (!allowed()) return null;
    if (saved != null) return saved;
    final key = '$logicalId:${kind.name}';
    final pending = _writes[key];
    if (pending != null && pending.allowed()) return pending.future;
    final operation = _persist(logicalId, kind, url, legacyTaskId, allowed);
    final write = _ArtworkWriteV2(operation, allowed);
    _writes[key] = write;
    try {
      return await operation;
    } finally {
      if (identical(_writes[key], write)) _writes.remove(key);
    }
  }

  Future<File?> _persist(
    String logicalId,
    DownloadArtworkKindV2 kind,
    String? url,
    String? legacyTaskId,
    bool Function() allowed,
  ) async {
    File? temporary;
    try {
      List<int>? bytes;
      if (kind == DownloadArtworkKindV2.episode && legacyTaskId != null) {
        final legacy = await existingLegacy(legacyTaskId);
        if (legacy != null) bytes = await _collectBytes(legacy.openRead());
      }
      final remote = url?.trim() ?? '';
      if (bytes == null && remote.isNotEmpty && allowed()) {
        File? cached;
        try {
          cached = await _cachedFileForUrl(remote).timeout(const Duration(seconds: 2));
        } catch (_) {
          // Cache failure does not prevent a bounded direct artwork fetch.
        }
        if (cached != null && await _validImage(cached)) {
          bytes = await _collectBytes(cached.openRead());
        }
        if (bytes == null && allowed()) {
          final uri = Uri.tryParse(remote);
          if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http') && uri.host.isNotEmpty) {
            bytes = await _fetchBytes(uri).timeout(_fetchTimeout);
          }
        }
      }
      if (!allowed() || bytes == null || bytes.isEmpty || bytes.length > _maxBytes) return null;
      final directory = await _ownedDirectory(logicalId, create: true);
      if (!allowed() || directory == null) return null;
      final target = File(p.join(directory.path, '${kind.name}.img'));
      final targetType = await FileSystemEntity.type(target.path, followLinks: false);
      if (targetType != FileSystemEntityType.notFound && targetType != FileSystemEntityType.file) return null;
      temporary = File('${target.path}.${_temporarySequence++}.tmp');
      if (await FileSystemEntity.type(temporary.path, followLinks: false) != FileSystemEntityType.notFound) return null;
      if (!allowed() || await _ownedDirectory(logicalId) == null) return null;
      await temporary.writeAsBytes(bytes, flush: true);
      if (!allowed() || !await _validImage(temporary)) return null;
      // Re-check owned parents and leaf after every asynchronous fetch/write.
      final checkedDirectory = await _ownedDirectory(logicalId);
      if (!allowed() || checkedDirectory == null || !p.equals(checkedDirectory.path, directory.path)) return null;
      final finalType = await FileSystemEntity.type(target.path, followLinks: false);
      if (finalType != FileSystemEntityType.notFound && finalType != FileSystemEntityType.file) return null;
      await _publishFile(temporary, target.path);
      return allowed() ? target : null;
    } catch (_) {
      return null;
    } finally {
      if (temporary != null) {
        try {
          final parent = await _ownedDirectory(logicalId);
          if (parent != null && p.equals(parent.path, temporary.parent.path) &&
              await FileSystemEntity.type(temporary.path, followLinks: false) == FileSystemEntityType.file) {
            await temporary.delete();
          }
        } catch (_) {}
      }
    }
  }

  Future<void> delete(String logicalId, {String? legacyTaskId}) async {
    // Fence queued jobs before any path lookup or filesystem await.
    _deletionEpochs[logicalId] = _epochFor(logicalId) + 1;
    try {
      final directory = await _ownedDirectory(logicalId);
      if (directory != null) await directory.delete(recursive: true);
      if (legacyTaskId != null) {
        final legacy = await legacyFileFor(legacyTaskId);
        if (legacy != null && await FileSystemEntity.type(legacy.path, followLinks: false) == FileSystemEntityType.file) await legacy.delete();
      }
    } catch (_) {}
  }

  static Future<File?> _cachedFile(String url) async => (await DefaultCacheManager().getFileFromCache(url))?.file;

  static Future<List<int>?> _collectBytes(Stream<List<int>> stream) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > _maxBytes) return null;
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  static Future<List<int>?> _fetchImage(Uri uri) async {
    final client = HttpClient()..connectionTimeout = _fetchTimeout;
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.maxRedirects = 3;
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok || response.contentLength > _maxBytes) return null;
        return _collectBytes(response);
      })().timeout(_fetchTimeout);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

final downloadArtworkStoreV2 = DownloadArtworkStoreV2();

Future<void> deleteDownloadArtworkV2(String logicalId, {String? legacyTaskId}) =>
    downloadArtworkStoreV2.delete(logicalId, legacyTaskId: legacyTaskId);

final class DownloadArtworkSourceV2 {
  const DownloadArtworkSourceV2({this.episodeUrl, this.posterUrl, this.legacyTaskId});
  final String? episodeUrl;
  final String? posterUrl;
  final String? legacyTaskId;
}

/// Capture is independent of screen lifetime and never delays a video slot.
/// Metadata is read once on first active and once on completed/recovered state.
final class DownloadArtworkObserverV2 implements DownloadPresentationObserverV2 {
  DownloadArtworkObserverV2({
    required Future<DownloadArtworkSourceV2?> Function(LogicalDownloadRecordV2) sourceFor,
    DownloadArtworkStoreV2? store,
  }) : _sourceFor = sourceFor, _store = store ?? downloadArtworkStoreV2;

  final Future<DownloadArtworkSourceV2?> Function(LogicalDownloadRecordV2) _sourceFor;
  final DownloadArtworkStoreV2 _store;
  final Set<String> _seen = <String>{};
  final Queue<_ArtworkJobV2> _queue = Queue<_ArtworkJobV2>();
  int _active = 0;
  bool _disposed = false;

  @override
  Future<void> observe(LogicalDownloadRecordV2 record, DownloadTransportSnapshot snapshot) {
    if (_disposed || record.mediaKind != DownloadMediaKind.videoEpisode || snapshot.taskId != record.taskId) return Future<void>.value();
    final complete = record.completedAtMillis != null;
    if (!complete && snapshot.status != DownloadTransportStatus.queued &&
        snapshot.status != DownloadTransportStatus.running && snapshot.status != DownloadTransportStatus.held) return Future<void>.value();
    final epoch = _store._epochFor(record.logicalId.value);
    final key = '${record.logicalId.value}:${record.generation}:$epoch:${complete ? 'complete' : 'active'}';
    if (!_seen.add(key)) return Future<void>.value();
    final job = _ArtworkJobV2(record, epoch);
    _queue.add(job);
    _drain();
    return job.finished.future;
  }

  void _drain() {
    while (!_disposed && _active < 2 && _queue.isNotEmpty) {
      final job = _queue.removeFirst();
      _active++;
      unawaited(_capture(job).whenComplete(() {
        _active--;
        job.finished.complete();
        _drain();
      }));
    }
  }

  Future<void> _capture(_ArtworkJobV2 job) async {
    bool alive() => !_disposed && _store._epochFor(job.record.logicalId.value) == job.epoch;
    try {
      if (!alive()) return;
      final source = await _sourceFor(job.record).timeout(const Duration(seconds: 20));
      if (!alive() || source == null) return;
      for (final kind in DownloadArtworkKindV2.values) {
        if (!alive()) return;
        await _store._ensure(
          logicalId: job.record.logicalId.value, kind: kind, epoch: job.epoch, alive: alive,
          url: kind == DownloadArtworkKindV2.episode ? source.episodeUrl : source.posterUrl,
          legacyTaskId: source.legacyTaskId,
        );
      }
    } catch (_) {
      // Artwork is best effort. It cannot fail a transfer or leak async errors.
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    while (_queue.isNotEmpty) {
      _queue.removeFirst().finished.complete();
    }
  }
}

final class _ArtworkWriteV2 {
  const _ArtworkWriteV2(this.future, this.allowed);
  final Future<File?> future;
  final bool Function() allowed;
}

final class _ArtworkJobV2 {
  _ArtworkJobV2(this.record, this.epoch);
  final LogicalDownloadRecordV2 record;
  final int epoch;
  final Completer<void> finished = Completer<void>();
}
