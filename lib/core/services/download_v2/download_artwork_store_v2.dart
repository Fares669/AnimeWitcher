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

import '../../network/poster_cache.dart';
import '../../utils/image_fallbacks.dart';
import 'download_continued_processing_v2.dart';
import 'download_v2_models.dart';
import 'download_v2_identity.dart';
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
       _publishFile =
           publishFile ??
           ((file, path) async {
             await file.rename(path);
           });

  static const int _maxBytes = 10 * 1024 * 1024;
  static const Duration _fetchTimeout = Duration(seconds: 20);
  final Future<Directory> Function() _supportDirectory;
  final Future<File?> Function(String) _cachedFileForUrl;
  final Future<List<int>?> Function(Uri) _fetchBytes;
  final Future<void> Function(File, String) _publishFile;
  final Map<String, int> _deletionEpochs = <String, int>{};
  final Map<String, _ArtworkWriteV2> _writes = <String, _ArtworkWriteV2>{};
  final Map<String, Future<void>> _publications = <String, Future<void>>{};
  final Map<String, Future<void>> _deletions = <String, Future<void>>{};
  int _activeFetches = 0;
  final Queue<Completer<void>> _fetchWaiters = Queue<Completer<void>>();

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

  Future<Directory?> _ownedDirectory(
    String logicalId, {
    bool create = false,
  }) async {
    if (kIsWeb || logicalId.trim().isEmpty) return null;
    final support = await _support();
    final root = await _childDirectory(
      support,
      'download_artwork_v2',
      create: create,
    );
    if (root == null) return null;
    return _childDirectory(
      root,
      sha256.convert(utf8.encode(logicalId)).toString(),
      create: create,
    );
  }

  Future<File?> legacyFileFor(String taskId) async {
    if (kIsWeb || taskId.trim().isEmpty) return null;
    try {
      final support = await _support();
      final directory = Directory(
        p.join(support.path, 'download_episode_artwork'),
      );
      final type = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.notFound &&
          (type != FileSystemEntityType.directory ||
              !p.equals(
                await directory.resolveSymbolicLinks(),
                directory.path,
              ))) {
        return null;
      }
      final key = sha1.convert(taskId.codeUnits).toString();
      return File(p.join(directory.path, '$key.img'));
    } catch (_) {
      return null;
    }
  }

  Future<bool> _validImage(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file)
      return false;
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
      // A replaced observer may still have an issued rename in flight. Never
      // return its bytes before the publication's obsolete-file cleanup settles.
      await _waitForPublication(logicalId);
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
    Iterable<String?> fallbackUrls = const [],
    String? legacyTaskId,
  }) => _ensure(
    logicalId: logicalId,
    kind: kind,
    url: url,
    fallbackUrls: fallbackUrls,
    legacyTaskId: legacyTaskId,
    epoch: _epochFor(logicalId),
    alive: () => true,
  );

  Future<File?> _ensure({
    required String logicalId,
    required DownloadArtworkKindV2 kind,
    required int epoch,
    required bool Function() alive,
    String? url,
    Iterable<String?> fallbackUrls = const [],
    String? legacyTaskId,
  }) async {
    bool allowed() => alive() && _epochFor(logicalId) == epoch;
    if (kIsWeb || logicalId.trim().isEmpty || !allowed()) return null;
    await _deletions[logicalId];
    if (!allowed()) return null;
    final saved = await existing(logicalId, kind);
    if (!allowed()) return null;
    if (saved != null) return saved;
    final key = '$logicalId:${kind.name}';
    final candidates = <String>{
      for (final value in [url, ...fallbackUrls])
        if (AppImageFallbacks.optional(value) case final String normalized)
          normalized,
    };
    final pending = _writes[key];
    if (pending != null && pending.allowed()) {
      final result = await pending.future;
      if (!allowed()) return null;
      if (result != null || candidates.every(pending.candidates.contains))
        return result;
      if (identical(_writes[key], pending)) _writes.remove(key);
      return _ensure(
        logicalId: logicalId,
        kind: kind,
        epoch: epoch,
        alive: alive,
        url: url,
        fallbackUrls: fallbackUrls,
        legacyTaskId: legacyTaskId,
      );
    }
    final operation = _persist(
      logicalId,
      kind,
      candidates,
      legacyTaskId,
      allowed,
    );
    final write = _ArtworkWriteV2(operation, allowed, candidates);
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
    Set<String> candidates,
    String? legacyTaskId,
    bool Function() allowed,
  ) async {
    Directory? staging;
    Future<File?> publishBytes(List<int>? bytes) async {
      if (!allowed() ||
          bytes == null ||
          bytes.isEmpty ||
          bytes.length > _maxBytes)
        return null;
      final directory = await _ownedDirectory(logicalId, create: true);
      if (!allowed() || directory == null) return null;
      if (staging == null) {
        if (!allowed() || await _ownedDirectory(logicalId) == null) return null;
        staging = await directory.createTemp('.artwork-');
      }
      if (!allowed() || !await _ownedStaging(logicalId, staging!)) return null;
      final temporary = File(p.join(staging!.path, 'pending.img'));
      await temporary.writeAsBytes(bytes, flush: true);
      if (!allowed() || !await _validImage(temporary)) return null;
      return _publish(
        logicalId,
        temporary,
        File(p.join(directory.path, '${kind.name}.img')),
        allowed,
      );
    }

    try {
      if (kind == DownloadArtworkKindV2.episode && legacyTaskId != null) {
        final legacy = await existingLegacy(legacyTaskId);
        if (legacy != null) {
          final saved = await publishBytes(
            await _collectBytes(legacy.openRead()),
          );
          if (saved != null) return saved;
        }
      }
      // Exhaust known disk copies before any request to a router without Internet.
      for (final remote in candidates) {
        if (!allowed()) return null;
        try {
          final cached = await _cachedFileForUrl(remote)
              .timeout(const Duration(seconds: 2));
          if (cached != null && await _validImage(cached)) {
            final saved = await publishBytes(
              await _collectBytes(cached.openRead()),
            );
            if (saved != null) return saved;
          }
        } catch (_) {
          // Try the next already-cached candidate.
        }
      }
      for (final remote in candidates) {
        if (!allowed()) return null;
        final uri = Uri.tryParse(remote);
        if (uri == null ||
            (uri.scheme != 'https' && uri.scheme != 'http') ||
            uri.host.isEmpty)
          continue;
        try {
          final saved = await publishBytes(await _fetchLimited(uri, allowed));
          if (saved != null) return saved;
        } catch (_) {
          // Missing or invalid artwork must not prevent the next fallback.
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      if (staging != null) {
        try {
          if (await _ownedStaging(logicalId, staging!))
            await staging!.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<bool> _ownedStaging(String logicalId, Directory staging) async {
    final parent = await _ownedDirectory(logicalId);
    return parent != null &&
        p.equals(parent.path, staging.parent.path) &&
        await FileSystemEntity.type(staging.path, followLinks: false) ==
            FileSystemEntityType.directory &&
        p.equals(await staging.resolveSymbolicLinks(), staging.path);
  }

  Future<void> _waitForPublication(String logicalId) =>
      _publications[logicalId] ?? Future<void>.value();

  Future<File?> _publish(
    String logicalId,
    File temporary,
    File target,
    bool Function() allowed,
  ) {
    final previous = _waitForPublication(logicalId);
    final operation = previous.then<File?>((_) async {
      final directory = await _ownedDirectory(logicalId);
      if (!allowed() ||
          directory == null ||
          !p.equals(directory.path, target.parent.path) ||
          !await _ownedStaging(logicalId, temporary.parent))
        return null;
      final type = await FileSystemEntity.type(target.path, followLinks: false);
      // Check after the last awaited stat, immediately before issuing rename.
      if (!allowed() ||
          (type != FileSystemEntityType.notFound &&
              type != FileSystemEntityType.file))
        return null;
      await _publishFile(temporary, target.path);
      if (allowed()) return target;
      // Keep the publication lock while removing our obsolete just-published
      // bytes. A replacement or deletion cannot race this cleanup.
      final checked = await _ownedDirectory(logicalId);
      if (checked != null &&
          p.equals(checked.path, target.parent.path) &&
          await FileSystemEntity.type(target.path, followLinks: false) ==
              FileSystemEntityType.file) {
        await target.delete();
      }
      return null;
    });
    final barrier = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _publications[logicalId] = barrier;
    return operation.whenComplete(() {
      if (identical(_publications[logicalId], barrier))
        _publications.remove(logicalId);
    });
  }

  Future<void> delete(String logicalId, {String? legacyTaskId}) {
    // Fence queued jobs before any path lookup or filesystem await.
    _deletionEpochs[logicalId] = _epochFor(logicalId) + 1;
    final previous = _deletions[logicalId] ?? Future<void>.value();
    final operation = previous.then((_) async {
      try {
        // Fetches never hold this barrier; only an already-issued publication.
        await _waitForPublication(logicalId);
        final directory = await _ownedDirectory(logicalId);
        if (directory != null) await directory.delete(recursive: true);
        if (legacyTaskId != null) {
          final legacy = await legacyFileFor(legacyTaskId);
          if (legacy != null &&
              await FileSystemEntity.type(legacy.path, followLinks: false) ==
                  FileSystemEntityType.file)
            await legacy.delete();
        }
      } catch (_) {}
    });
    _deletions[logicalId] = operation;
    return operation.whenComplete(() {
      if (identical(_deletions[logicalId], operation))
        _deletions.remove(logicalId);
    });
  }

  Future<List<int>?> _fetchLimited(Uri uri, bool Function() allowed) async {
    if (_activeFetches >= 2) {
      final ready = Completer<void>();
      _fetchWaiters.add(ready);
      await ready.future;
    } else {
      _activeFetches++;
    }
    try {
      if (!allowed()) return null;
      return await _fetchBytes(uri).timeout(_fetchTimeout);
    } finally {
      if (_fetchWaiters.isNotEmpty) {
        // Transfer this permit directly to the oldest waiter.
        _fetchWaiters.removeFirst().complete();
      } else {
        _activeFetches--;
      }
    }
  }

  static Future<File?> _cachedFile(String url) async {
    for (final cache in [DefaultCacheManager(), posterCacheManager]) {
      try {
        final file =
            (await cache
                    .getFileFromCache(url)
                    .timeout(const Duration(seconds: 1)))
                ?.file;
        if (file != null &&
            await file.exists() &&
            await file.length() <= _maxBytes &&
            await isMangaPageImageV2(file))
          return file;
      } catch (_) {}
    }
    return null;
  }

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
        if (response.statusCode != HttpStatus.ok ||
            response.contentLength > _maxBytes)
          return null;
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

Future<void> deleteDownloadArtworkV2(
  String logicalId, {
  String? legacyTaskId,
}) => downloadArtworkStoreV2.delete(logicalId, legacyTaskId: legacyTaskId);

/// Legacy artwork is never assigned from a title, URL alias, or record-supplied
/// variant. Its saved metadata must independently identify this exact record.
bool downloadArtworkMetadataMatchesRecordV2(
  Map<String, dynamic> metadata,
  LogicalDownloadRecordV2 record,
) {
  final declared = metadata['logicalId'];
  if (declared != null) {
    return declared is String && declared.trim() == record.logicalId.value;
  }
  if (record.mediaKind != DownloadMediaKind.videoEpisode) return false;
  final rawItem = metadata['item'];
  final variant = metadata['variantKey'];
  final unit = metadata['trackingUrl'];
  if (rawItem is! Map ||
      variant is! String ||
      variant.trim().isEmpty ||
      unit is! String ||
      unit.trim().isEmpty)
    return false;
  final tmdb = rawItem['tmdbId'];
  final imdb = rawItem['imdbId'];
  final url = rawItem['url'];
  final media = tmdb != null
      ? tmdb.toString().trim()
      : imdb is String && imdb.trim().isNotEmpty
      ? imdb.trim()
      : url is String
      ? url.trim()
      : '';
  if (media.isEmpty ||
      media != record.mediaId ||
      unit.trim() != record.unitKey ||
      variant.trim() != record.variantKey)
    return false;
  return logicalDownloadIdFor(
        animeId: media,
        episodeKey: unit,
        variantKey: variant,
      ) ==
      record.logicalId;
}

final class DownloadArtworkSourceV2 {
  const DownloadArtworkSourceV2({
    this.episodeUrl,
    this.posterUrl,
    this.bannerUrl,
    this.legacyTaskId,
  });
  final String? episodeUrl;
  final String? bannerUrl;
  final String? posterUrl;
  final String? legacyTaskId;
}

/// Capture is independent of screen lifetime and never delays a video slot.
/// Metadata is read once on first active and once on completed/recovered state.
final class DownloadArtworkObserverV2
    implements DownloadPresentationObserverV2 {
  DownloadArtworkObserverV2({
    required Future<DownloadArtworkSourceV2?> Function(LogicalDownloadRecordV2)
    sourceFor,
    DownloadArtworkStoreV2? store,
    DateTime Function()? now,
  }) : _sourceFor = sourceFor,
       _store = store ?? downloadArtworkStoreV2,
       _now = now ?? DateTime.now;

  final Future<DownloadArtworkSourceV2?> Function(LogicalDownloadRecordV2)
  _sourceFor;
  final DownloadArtworkStoreV2 _store;
  final Set<String> _seen = <String>{};
  final DateTime Function() _now;
  final Map<String, DateTime> _retryAfter = {};
  final Queue<_ArtworkJobV2> _queue = Queue<_ArtworkJobV2>();
  int _active = 0;
  final Set<_ArtworkJobV2> _activeJobs = <_ArtworkJobV2>{};
  bool _disposed = false;

  @override
  Future<void> observe(
    LogicalDownloadRecordV2 record,
    DownloadTransportSnapshot snapshot,
  ) {
    if (_disposed ||
        record.mediaKind != DownloadMediaKind.videoEpisode ||
        snapshot.taskId != record.taskId)
      return Future<void>.value();
    final complete = record.completedAtMillis != null;
    if (!complete &&
        snapshot.status != DownloadTransportStatus.queued &&
        snapshot.status != DownloadTransportStatus.running &&
        snapshot.status != DownloadTransportStatus.held)
      return Future<void>.value();
    final epoch = _store._epochFor(record.logicalId.value);
    final key =
        '${record.logicalId.value}:${record.generation}:$epoch:${complete ? 'complete' : 'active'}';
    final retryAt = _retryAfter[key];
    if (retryAt != null && _now().isBefore(retryAt))
      return Future<void>.value();
    if (!_seen.add(key)) return Future<void>.value();
    _retryAfter.remove(key);
    final job = _ArtworkJobV2(record, epoch, key);
    _queue.add(job);
    _drain();
    return job.finished.future;
  }

  void _drain() {
    while (!_disposed && _active < 2 && _queue.isNotEmpty) {
      final job = _queue.removeFirst();
      _active++;
      _activeJobs.add(job);
      unawaited(
        _capture(job).whenComplete(() {
          _active--;
          _activeJobs.remove(job);
          job.finished.complete();
          _drain();
        }),
      );
    }
  }

  Future<void> _capture(_ArtworkJobV2 job) async {
    bool alive() =>
        !_disposed && _store._epochFor(job.record.logicalId.value) == job.epoch;
    var retained = false;
    try {
      if (!alive()) return;
      final source = await _sourceFor(job.record)
          .timeout(const Duration(seconds: 20));
      if (!alive() || source == null) return;
      retained = true;
      for (final kind in DownloadArtworkKindV2.values) {
        if (!alive()) return;
        final saved = await _store._ensure(
          logicalId: job.record.logicalId.value,
          kind: kind,
          epoch: job.epoch,
          alive: alive,
          url: kind == DownloadArtworkKindV2.episode
              ? source.episodeUrl
              : source.posterUrl,
          fallbackUrls: kind == DownloadArtworkKindV2.episode
              ? [source.bannerUrl, source.posterUrl]
              : const [],
          legacyTaskId: source.legacyTaskId,
        );
        final candidates = kind == DownloadArtworkKindV2.episode
            ? [source.episodeUrl, source.bannerUrl, source.posterUrl]
            : [source.posterUrl];
        if (saved == null &&
            candidates.any((url) => AppImageFallbacks.optional(url) != null)) {
          retained = false;
        }
      }
    } catch (_) {
      retained = false;
      // Artwork cannot fail a transfer or leak async errors.
    } finally {
      if (!retained && alive()) {
        _seen.remove(job.key);
        _retryAfter[job.key] = _now().add(const Duration(seconds: 30));
      }
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    while (_queue.isNotEmpty) {
      _queue.removeFirst().finished.complete();
    }
    await Future.wait(
      _activeJobs
          .map((job) => _store._waitForPublication(job.record.logicalId.value))
          .toList(growable: false),
    );
  }
}

final class _ArtworkWriteV2 {
  const _ArtworkWriteV2(this.future, this.allowed, this.candidates);
  final Set<String> candidates;
  final Future<File?> future;
  final bool Function() allowed;
}

final class _ArtworkJobV2 {
  _ArtworkJobV2(this.record, this.epoch, this.key);
  final String key;
  final LogicalDownloadRecordV2 record;
  final int epoch;
  final Completer<void> finished = Completer<void>();
}
