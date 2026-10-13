import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/download_artwork_store_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/manga_image_fixtures.dart';

void main() {
  late Directory root;
  setUp(() async { root = await Directory.systemTemp.createTemp('aw-artwork-'); });
  tearDown(() async { if (await root.exists()) await root.delete(recursive: true); });

  DownloadArtworkStoreV2 store({
    Future<File?> Function(String)? cachedFileForUrl,
    Future<List<int>?> Function(Uri)? fetchBytes,
  }) => DownloadArtworkStoreV2(
    supportDirectory: () async => root,
    cachedFileForUrl: cachedFileForUrl ?? (_) async => null,
    fetchBytes: fetchBytes ?? (_) async => throw StateError('offline'),
  );

  test('logical copies survive cache eviction and restart; deleting one retains the other poster', () async {
    final cache = await File('${root.path}/cache.img').writeAsBytes(tinyMangaPng);
    final initial = store(cachedFileForUrl: (_) async => cache);
    for (final id in ['episode-one', 'episode-two']) {
      for (final kind in DownloadArtworkKindV2.values) {
        final file = await initial.ensure(logicalId: id, kind: kind, url: 'https://example.test/shared.png');
        expect(file, isNotNull);
        expect(await file!.readAsBytes(), tinyMangaPng);
      }
    }
    await cache.delete();
    final restarted = store();
    for (final id in ['episode-one', 'episode-two']) {
      for (final kind in DownloadArtworkKindV2.values) {
        expect(await restarted.ensure(logicalId: id, kind: kind), isNotNull);
      }
    }
    await restarted.delete('episode-one');
    for (final kind in DownloadArtworkKindV2.values) {
      expect(await restarted.existing('episode-one', kind), isNull);
      final remaining = await restarted.existing('episode-two', kind);
      expect(await remaining!.readAsBytes(), tinyMangaPng);
    }
  });

  test('legacy migration and deletion touch only the supplied exact task artwork', () async {
    final artwork = store();
    final exact = (await artwork.legacyFileFor('exact-task'))!;
    final unrelated = (await artwork.legacyFileFor('other-task'))!;
    await exact.parent.create(recursive: true);
    await exact.writeAsBytes(tinyMangaPng);
    await unrelated.writeAsBytes(tinyMangaPng);
    final migrated = await artwork.ensure(
      logicalId: 'exact-logical', kind: DownloadArtworkKindV2.episode,
      legacyTaskId: 'exact-task',
    );
    expect(migrated, isNotNull);
    expect(migrated!.path, isNot(exact.path));
    expect(await migrated.readAsBytes(), tinyMangaPng);
    await artwork.delete('exact-logical', legacyTaskId: 'exact-task');
    expect(await exact.exists(), isFalse);
    expect(await unrelated.readAsBytes(), tinyMangaPng);
  });

  test('deletion fences a pending fetch and prevents artwork recreation', () async {
    final started = Completer<void>();
    final bytes = Completer<List<int>?>();
    final artwork = store(fetchBytes: (_) {
      started.complete();
      return bytes.future;
    });
    final pending = artwork.ensure(
      logicalId: 'deleted', kind: DownloadArtworkKindV2.poster,
      url: 'https://example.test/late.png',
    );
    await started.future.timeout(const Duration(seconds: 2));
    await artwork.delete('deleted');
    bytes.complete(tinyMangaPng);
    expect(await pending, isNull);
    expect(await artwork.existing('deleted', DownloadArtworkKindV2.poster), isNull);
  });

  test('invalid or oversized artwork never changes an existing video', () async {
    final video = await File('${root.path}/video.mp4').writeAsBytes([1, 2, 3]);
    for (final bytes in [<int>[60, 104, 116, 109, 108, 62], List<int>.filled(10 * 1024 * 1024 + 1, 0)]) {
      final artwork = store(fetchBytes: (_) async => bytes);
      expect(await artwork.ensure(
        logicalId: 'invalid', kind: DownloadArtworkKindV2.episode,
        url: 'https://example.test/bad',
      ), isNull);
      expect(await artwork.existing('invalid', DownloadArtworkKindV2.episode), isNull);
      expect(await video.readAsBytes(), [1, 2, 3]);
    }
  });

  test('symlinked owned leaf is neither read nor followed during deletion', () async {
    if (Platform.isWindows) return;
    final artwork = store(fetchBytes: (_) async => tinyMangaPng);
    final saved = (await artwork.ensure(
      logicalId: 'linked', kind: DownloadArtworkKindV2.poster,
      url: 'https://example.test/poster',
    ))!;
    final outside = await File('${root.path}/outside.img').writeAsBytes(tinyMangaPng);
    await saved.delete();
    await Link(saved.path).create(outside.path);
    expect(await artwork.existing('linked', DownloadArtworkKindV2.poster), isNull);
    expect(await artwork.ensure(logicalId: 'linked', kind: DownloadArtworkKindV2.poster, url: 'https://example.test/poster'), isNull);
    await artwork.delete('linked');
    expect(await outside.readAsBytes(), tinyMangaPng);
  });

  test('symlinked private root and logical directory never escape app-owned storage', () async {
    if (Platform.isWindows) return;
    final outside = await Directory('${root.path}/outside').create();
    final marker = await File('${outside.path}/poster.img').writeAsBytes(tinyMangaPng);
    final privateRoot = '${root.path}/download_artwork_v2';
    await Link(privateRoot).create(outside.path);
    final artwork = store(fetchBytes: (_) async => tinyMangaPng);
    expect(await artwork.ensure(logicalId: 'linked-root', kind: DownloadArtworkKindV2.poster, url: 'https://example.test/poster'), isNull);
    await artwork.delete('linked-root');
    expect(await marker.readAsBytes(), tinyMangaPng);
    await Link(privateRoot).delete();
    final saved = (await artwork.ensure(logicalId: 'linked-directory', kind: DownloadArtworkKindV2.poster, url: 'https://example.test/poster'))!;
    await saved.parent.delete(recursive: true);
    await Link(saved.parent.path).create(outside.path);
    expect(await artwork.existing('linked-directory', DownloadArtworkKindV2.poster), isNull);
    expect(await artwork.ensure(logicalId: 'linked-directory', kind: DownloadArtworkKindV2.poster, url: 'https://example.test/poster'), isNull);
    await artwork.delete('linked-directory');
    expect(await marker.readAsBytes(), tinyMangaPng);
  });

  test('a symlinked temporary leaf is rejected without touching its target', () async {
    if (Platform.isWindows) return;
    final artwork = store(fetchBytes: (_) async => tinyMangaPng);
    final saved = (await artwork.ensure(logicalId: 'linked-temp', kind: DownloadArtworkKindV2.poster, url: 'https://example.test/poster'))!;
    await saved.delete();
    final outside = await File('${root.path}/outside-temp.img').writeAsBytes(tinyMangaJpeg);
    await Link('${saved.path}.1.tmp').create(outside.path);
    expect(await artwork.ensure(logicalId: 'linked-temp', kind: DownloadArtworkKindV2.poster, url: 'https://example.test/poster'), isNotNull);
    expect(await FileSystemEntity.type('${saved.path}.1.tmp', followLinks: false), FileSystemEntityType.link);
    await artwork.delete('linked-temp');
    expect(await outside.readAsBytes(), tinyMangaJpeg);
  });

  test('an operation never cleans a pre-existing regular staging leaf', () async {
    final artwork = store(fetchBytes: (_) async => tinyMangaPng);
    final saved = (await artwork.ensure(logicalId: 'existing-staging', kind: DownloadArtworkKindV2.poster, url: 'https://example.test/poster'))!;
    await saved.delete();
    final preexisting = await File('${saved.path}.1.tmp').writeAsBytes(tinyMangaJpeg);
    await artwork.ensure(logicalId: 'existing-staging', kind: DownloadArtworkKindV2.poster, url: 'https://example.test/poster');
    expect(await preexisting.exists(), isTrue);
    expect(await preexisting.readAsBytes(), tinyMangaJpeg);
  });

  test('observer disposal waits for an already issued publication before replacement', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    var publications = 0;
    final artwork = DownloadArtworkStoreV2(
      supportDirectory: () async => root, cachedFileForUrl: (_) async => null,
      fetchBytes: (_) async => tinyMangaPng,
      publishFile: (file, target) async {
        if (++publications == 1) {
          started.complete();
          await release.future.timeout(const Duration(seconds: 5));
        }
        await file.rename(target);
      },
    );
    final observer = DownloadArtworkObserverV2(store: artwork, sourceFor: (_) async =>
      const DownloadArtworkSourceV2(posterUrl: 'https://example.test/poster'));
    final record = _record('publication-race');
    final capture = observer.observe(record, _snapshot(record));
    await started.future.timeout(const Duration(seconds: 2));
    var disposed = false;
    final disposal = observer.dispose().then((_) { disposed = true; });
    try {
      await Future<void>.value();
      expect(disposed, isFalse, reason: 'an issued filesystem publication must settle before replacement');
    } finally {
      release.complete();
      await capture;
      await disposal;
    }
    expect(await artwork.existing(record.logicalId.value, DownloadArtworkKindV2.poster), isNull);
    final replacement = DownloadArtworkObserverV2(store: artwork, sourceFor: (_) async =>
      const DownloadArtworkSourceV2(posterUrl: 'https://example.test/poster'));
    addTearDown(replacement.dispose);
    await replacement.observe(record, _snapshot(record));
    expect(await artwork.existing(record.logicalId.value, DownloadArtworkKindV2.poster), isNotNull);
  });

  test('replacement cannot reuse obsolete bytes while the prior rename is settling', () async {
    final renamed = Completer<void>();
    final release = Completer<void>();
    final replacementStarted = Completer<void>();
    var fetches = 0;
    var publications = 0;
    final artwork = DownloadArtworkStoreV2(
      supportDirectory: () async => root, cachedFileForUrl: (_) async => null,
      fetchBytes: (_) async => ++fetches == 1 ? tinyMangaJpeg : tinyMangaPng,
      publishFile: (file, target) async {
        await file.rename(target);
        if (++publications == 1) {
          renamed.complete();
          await release.future.timeout(const Duration(seconds: 5));
        }
      },
    );
    final record = _record('replacement-read');
    final original = DownloadArtworkObserverV2(store: artwork, sourceFor: (_) async =>
      const DownloadArtworkSourceV2(posterUrl: 'https://example.test/poster'));
    final oldCapture = original.observe(record, _snapshot(record));
    await renamed.future.timeout(const Duration(seconds: 2));
    final disposal = original.dispose();
    final replacement = DownloadArtworkObserverV2(store: artwork, sourceFor: (_) async {
      replacementStarted.complete();
      return const DownloadArtworkSourceV2(posterUrl: 'https://example.test/poster');
    });
    addTearDown(replacement.dispose);
    final capture = replacement.observe(record, _snapshot(record));
    final completed = capture.then((_) => true);
    var completedBeforeRelease = false;
    try {
      await replacementStarted.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);
      completedBeforeRelease = await completed.timeout(
        const Duration(milliseconds: 250), onTimeout: () => false,
      );
    } finally {
      release.complete();
      await oldCapture;
      await disposal;
      await capture;
    }
    expect(completedBeforeRelease, isFalse, reason: 'replacement must wait only for the issued publication');
    final retained = await artwork.existing(record.logicalId.value, DownloadArtworkKindV2.poster);
    expect(retained, isNotNull);
    expect(await retained!.readAsBytes(), tinyMangaPng);
    expect(fetches, 2);
    expect(publications, 2);
  });

  test('default HTTP fetch rejects an oversized streamed response before publishing', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final served = Completer<void>();
    unawaited(server.first.then((request) async {
      try {
        for (var index = 0; index < 12; index++) {
          request.response.add(List<int>.filled(1024 * 1024, 0));
          await request.response.flush();
        }
      } catch (_) {
        // Closing the oversized client is expected.
      } finally {
        try { await request.response.close(); } catch (_) {}
        served.complete();
      }
    }));
    final artwork = DownloadArtworkStoreV2(
      supportDirectory: () async => root, cachedFileForUrl: (_) async => null,
    );
    expect(await artwork.ensure(
      logicalId: 'stream-limit', kind: DownloadArtworkKindV2.poster,
      url: 'http://127.0.0.1:${server.port}/oversized',
    ), isNull);
    expect(await artwork.existing('stream-limit', DownloadArtworkKindV2.poster), isNull);
    await served.future.timeout(const Duration(seconds: 5));
  });

  test('disposed observer cannot publish its late fetch after replacement', () async {
    final started = Completer<void>();
    final oldBytes = Completer<List<int>?>();
    var calls = 0;
    final artwork = store(fetchBytes: (_) {
      if (++calls == 1) {
        started.complete();
        return oldBytes.future;
      }
      return Future.value(tinyMangaPng);
    });
    Future<DownloadArtworkSourceV2?> source(LogicalDownloadRecordV2 _) async =>
      const DownloadArtworkSourceV2(posterUrl: 'https://example.test/poster');
    final oldObserver = DownloadArtworkObserverV2(store: artwork, sourceFor: source);
    final record = _record('recreated');
    final oldCapture = oldObserver.observe(record, _snapshot(record));
    await started.future.timeout(const Duration(seconds: 2));
    await oldObserver.dispose();
    final newObserver = DownloadArtworkObserverV2(store: artwork, sourceFor: source);
    addTearDown(newObserver.dispose);
    await newObserver.observe(record.copyWith(completedAtMillis: 1), _snapshot(record, complete: true));
    oldBytes.complete(tinyMangaJpeg);
    await oldCapture;
    final retained = await artwork.existing('recreated', DownloadArtworkKindV2.poster);
    expect(await retained!.readAsBytes(), tinyMangaPng);
    expect(calls, 2);
  });

  test('UI backfill also shares the store network concurrency ceiling', () async {
    var active = 0;
    var peak = 0;
    final artwork = store(fetchBytes: (_) async {
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      active--;
      return tinyMangaPng;
    });
    await Future.wait([for (var index = 0; index < 8; index++) artwork.ensure(
      logicalId: 'ui-$index', kind: DownloadArtworkKindV2.poster, url: 'https://example.test/poster',
    )]);
    expect(peak, 2);
  });

  test('observer captures background records once per phase with bounded concurrency', () async {
    var active = 0;
    var peak = 0;
    var metadataReads = 0;
    final artwork = store(fetchBytes: (_) async {
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      active--;
      return tinyMangaPng;
    });
    final observer = DownloadArtworkObserverV2(store: artwork, sourceFor: (_) async {
      metadataReads++;
      return const DownloadArtworkSourceV2(episodeUrl: 'https://example.test/episode', posterUrl: 'https://example.test/poster');
    });
    addTearDown(observer.dispose);
    final records = List.generate(6, (index) => _record('background-$index'));
    await Future.wait([
      for (final record in records) observer.observe(record, _snapshot(record)),
      for (var update = 0; update < 10; update++) observer.observe(records.first, _snapshot(records.first)),
    ]);
    expect(metadataReads, records.length);
    expect(peak, 2);
    for (final record in records) {
      expect(await artwork.existing(record.logicalId.value, DownloadArtworkKindV2.episode), isNotNull);
      expect(await artwork.existing(record.logicalId.value, DownloadArtworkKindV2.poster), isNotNull);
    }
    await observer.observe(records.first.copyWith(completedAtMillis: 1), _snapshot(records.first, complete: true));
    expect(metadataReads, records.length + 1);
    await observer.observe(records.first.copyWith(completedAtMillis: 1), _snapshot(records.first, complete: true));
    expect(metadataReads, records.length + 1);
  });

  test('deletion also fences an observer capture waiting behind the concurrency limit', () async {
    final started = Completer<void>();
    final release = Completer<List<int>?>();
    var calls = 0;
    final artwork = store(fetchBytes: (_) {
      if (++calls == 2) started.complete();
      return release.future;
    });
    final observer = DownloadArtworkObserverV2(store: artwork, sourceFor: (_) async =>
      const DownloadArtworkSourceV2(posterUrl: 'https://example.test/poster'));
    addTearDown(observer.dispose);
    final records = [_record('first'), _record('second'), _record('queued-deleted')];
    final captures = [for (final record in records) observer.observe(record, _snapshot(record))];
    await started.future.timeout(const Duration(seconds: 2));
    await artwork.delete('queued-deleted');
    release.complete(tinyMangaPng);
    await Future.wait(captures);
    expect(calls, 2);
    expect(await artwork.existing('queued-deleted', DownloadArtworkKindV2.poster), isNull);
  });

  test('same observer captures a re-download even when logical and generation-one task IDs are reused', () async {
    var reads = 0;
    final artwork = store(fetchBytes: (_) async => tinyMangaPng);
    final observer = DownloadArtworkObserverV2(store: artwork, sourceFor: (_) async {
      reads++;
      return const DownloadArtworkSourceV2(posterUrl: 'https://example.test/poster');
    });
    addTearDown(observer.dispose);
    final record = _record('download-again');
    await observer.observe(record, _snapshot(record));
    await artwork.delete(record.logicalId.value);
    expect(await artwork.existing(record.logicalId.value, DownloadArtworkKindV2.poster), isNull);
    await observer.observe(record, _snapshot(record));
    expect(reads, 2);
    expect(await artwork.existing(record.logicalId.value, DownloadArtworkKindV2.poster), isNotNull);
  });

  test('observer handles metadata errors internally and captures recovered completion', () async {
    var reads = 0;
    final artwork = store(fetchBytes: (_) async => tinyMangaPng);
    final observer = DownloadArtworkObserverV2(store: artwork, sourceFor: (_) async {
      if (++reads == 1) throw StateError('display metadata unavailable');
      return const DownloadArtworkSourceV2(posterUrl: 'https://example.test/poster');
    });
    addTearDown(observer.dispose);
    final record = _record('recover');
    await observer.observe(record, _snapshot(record));
    await observer.observe(record.copyWith(completedAtMillis: 1), _snapshot(record, complete: true));
    expect(await artwork.existing(record.logicalId.value, DownloadArtworkKindV2.poster), isNotNull);
  });
}

LogicalDownloadRecordV2 _record(String id) => LogicalDownloadRecordV2(
  schemaVersion: kLogicalDownloadSchemaVersionV2, logicalId: DownloadLogicalId(id),
  mediaId: 'saved-show', unitKey: id, variantKey: 'original', generation: 1,
  taskId: 'task-$id', intent: DownloadUserIntent.active, destinationPath: '$id.mp4',
  sourceDescriptor: const {}, updatedAtMillis: 1,
);
DownloadTransportSnapshot _snapshot(LogicalDownloadRecordV2 record, {bool complete = false}) => DownloadTransportSnapshot(
  taskId: record.taskId, status: complete ? DownloadTransportStatus.complete : DownloadTransportStatus.running,
  progress: complete ? 1 : .2,
);
