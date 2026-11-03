import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_url_refresh.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/download_persistence_worker.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/details/presentation/download_launcher.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

const _rift = 'com.animerift.provider';
const _native = 'com.fares669.animewitcher.native';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Rift logical ID ignores www and transient query aliases only for Rift',
    () {
      DownloadLogicalId id(String media, String unit, String provider) =>
          logicalDownloadIdFor(
            animeId: media,
            episodeKey: unit,
            variantKey: 'sub|1080p',
            providerId: provider,
          );
      expect(
        id(
          'https://www.anime-rift.com/anime/42?token=old',
          'https://www.anime-rift.com/episode/7?token=old',
          _rift,
        ),
        id(
          'https://anime-rift.com/anime/42',
          'https://anime-rift.com/episode/7',
          _rift,
        ),
      );
      expect(
        id('https://www.anime-rift.com/anime/42', 'episode/7', _native),
        isNot(id('https://anime-rift.com/anime/42', 'episode/7', _native)),
      );
      expect(
        id('https://anime-rift.com/anime/42', 'episode/8', _rift),
        isNot(id('https://anime-rift.com/anime/42', 'episode/7', _rift)),
      );
    },
  );

  test(
    'batch recognizes legacy Rift alias rows without changing IDs or paths',
    () async {
      final row = _record(provider: _rift);
      final before = jsonEncode(row.toJson());
      final store = InMemoryLogicalDownloadStoreV2();
      await store.put(row);
      final rows = await store.all();
      expect(
        existingBatchEpisodeKeysForProviderV2(
          rows,
          mediaId: 'https://anime-rift.com/anime/42',
          providerId: _rift,
        ),
        {'https://anime-rift.com/episode/7'},
      );
      expect(
        existingBatchEpisodeKeysForProviderV2(
          rows,
          mediaId: 'https://anime-rift.com/anime/42',
          providerId: _native,
        ),
        isEmpty,
      );
      expect(jsonEncode((await store.get(row.logicalId))!.toJson()), before);
    },
  );

  test('Rift refresh serialization retains stable identity and drops transport tokens', () {
    const descriptor = DownloadUrlRefreshDescriptor(
      trackingUrl:
          'https://www.anime-rift.com/episode/7?token=EPISODE_SECRET#private',
      providerId: _rift,
      source: 'Server A',
      quality: '1080p',
      refreshUrl: 'https://cdn.invalid/play?token=REFRESH_SECRET',
      updatedAtMillis: 123,
      generation: 4,
      ownerTaskId: 'task',
      logicalId: 'logical',
    );
    final json = descriptor.toJson();
    expect(json['trackingUrl'], 'https://anime-rift.com/episode/7');
    expect(json.containsKey('refreshUrl'), isFalse);
    expect(json['generation'], 4);
    expect(json['ownerTaskId'], 'task');
    expect(jsonEncode(json), isNot(contains('SECRET')));
    final restored = DownloadUrlRefreshDescriptor.fromJson({
      ...json,
      'trackingUrl': descriptor.trackingUrl,
      'refreshUrl': descriptor.refreshUrl,
    });
    expect(restored?.trackingUrl, 'https://anime-rift.com/episode/7');
    expect(restored?.refreshUrl, isNull);
  });

  test(
    'Rift refuses a signed external transport URL as a renewal identity',
    () {
      expect(
        DownloadUrlRefreshDescriptor.fromJson({
          'providerId': _rift,
          'source': 'Server A',
          'trackingUrl': 'https://cdn.invalid/video.mp4?token=SECRET',
          'updatedAtMillis': 1,
        }),
        isNull,
      );
    },
  );

  test(
    'durable Rift source descriptor contains no arbitrary nested payload',
    () async {
      final store = InMemoryLogicalDownloadStoreV2();
      final row = _record(
        provider: _rift,
        descriptor: {
          'providerId': _rift,
          'source': 'Server A',
          'trackingUrl':
              'https://www.anime-rift.com/episode/7?token=TRACK_SECRET',
          'refreshUrl': 'https://cdn.invalid/video?token=REFRESH_SECRET',
          'headers': {'Authorization': 'HEADER_SECRET'},
          'streams': [
            {'drmKey': 'DRM_SECRET', 'url': 'https://cdn.invalid/signed'},
          ],
          'updatedAtMillis': 1,
        },
      );
      await store.put(row);
      final restored = (await store.get(row.logicalId))!;
      expect(restored.logicalId, row.logicalId);
      expect(restored.destinationPath, row.destinationPath);
      expect(
        restored.sourceDescriptor['trackingUrl'],
        'https://anime-rift.com/episode/7',
      );
      expect(
        restored.sourceDescriptor.keys,
        unorderedEquals([
          'providerId',
          'source',
          'trackingUrl',
          'updatedAtMillis',
        ]),
      );
      expect(jsonEncode(restored.toJson()), isNot(contains('SECRET')));
    },
  );

  test('offline completed lookup recognizes Rift aliases without changing provider', () {
    final downloaded = DownloadItem(
      task: DownloadTask(
        taskId: 'legacy',
        url: 'https://invalid.test/stable',
        filename: 'old.mp4',
      ),
      item: MultimediaItem(
        title: 'Show',
        url: 'https://www.anime-rift.com/anime/42',
        posterUrl: '',
        provider: _rift,
      ),
      trackingUrl: 'https://www.anime-rift.com/episode/7?token=old',
      status: TaskStatus.complete,
      progress: 1,
      timestamp: 1,
      logicalId: 'dl_legacy_unmodified',
      destinationPath: '/downloads/old.mp4',
    );
    final parent = MultimediaItem(
      title: 'Show',
      url: 'https://anime-rift.com/anime/42',
      posterUrl: '',
      provider: _rift,
    );
    final episode = Episode(name: '7', url: 'https://anime-rift.com/episode/7');
    expect(
      completedEpisodeDownload([downloaded], parent, episode),
      same(downloaded),
    );
    expect(
      completedEpisodeDownload(
        [downloaded],
        parent.copyWith(provider: _native),
        episode,
      ),
      isNull,
    );
    expect(downloaded.logicalId, 'dl_legacy_unmodified');
    expect(downloaded.destinationPath, '/downloads/old.mp4');
  });

  test(
    'refresh store recovers descriptors through canonical and legacy www keys',
    () async {
      final backend = _RefreshBackend();
      final store = DownloadUrlRefreshStore(
        backend,
        now: () => DateTime.fromMillisecondsSinceEpoch(100),
      );
      await store.save(
        const DownloadUrlRefreshDescriptor(
          providerId: _rift,
          source: 'A',
          trackingUrl: 'https://www.anime-rift.com/episode/7?token=SECRET',
          refreshUrl: 'https://cdn.invalid/signed?token=SECRET',
          updatedAtMillis: 100,
        ),
      );
      expect(
        (await store.get('https://anime-rift.com/episode/7'))?.trackingUrl,
        'https://anime-rift.com/episode/7',
      );
      expect(jsonEncode(backend.rows), isNot(contains('SECRET')));
      final legacyBackend = _RefreshBackend();
      final legacyStore = DownloadUrlRefreshStore(
        legacyBackend,
        now: () => DateTime.fromMillisecondsSinceEpoch(100),
      );
      legacyBackend.rows['9043e5afe4697ad31bd89622b17e8417'] = {
        'providerId': _rift,
        'source': 'A',
        'trackingUrl': 'https://www.anime-rift.com/episode/7',
        'updatedAtMillis': 100,
        'generation': 2,
        'ownerTaskId': 'old-task',
        'logicalId': 'old-logical',
      };
      expect(
        (await legacyStore.get('https://anime-rift.com/episode/7'))
            ?.ownerTaskId,
        'old-task',
      );
    },
  );

  test(
    'refresh ownership treats Rift canonical and www aliases as one keyspace',
    () async {
      final backend = _RefreshBackend();
      final store = DownloadUrlRefreshStore(
        backend,
        now: () => DateTime.fromMillisecondsSinceEpoch(100),
      );
      final legacyKey = store.keyFor('https://www.anime-rift.com/episode/7');
      backend.rows[legacyKey] = <String, dynamic>{
        'providerId': _rift,
        'source': 'A',
        'trackingUrl': 'https://www.anime-rift.com/episode/7',
        'updatedAtMillis': 100,
        'generation': 2,
        'ownerTaskId': 'other-task',
        'logicalId': 'other-logical',
      };

      final claimed = await store.claimOwnership(
        const DownloadUrlRefreshDescriptor(
          providerId: _rift,
          source: 'A',
          trackingUrl: 'https://anime-rift.com/episode/7',
          updatedAtMillis: 100,
          generation: 3,
          ownerTaskId: 'new-task',
          logicalId: 'new-logical',
        ),
      );

      expect(claimed, isFalse);
      expect(backend.rows, hasLength(1));
      expect(
        (await store.get('https://anime-rift.com/episode/7'))?.ownerTaskId,
        'other-task',
      );
    },
  );

  test(
    'owner cleanup deletes Rift descriptors through either host alias',
    () async {
      for (final cleanupUrl in const <String>[
        'https://www.anime-rift.com/episode/7',
        'https://anime-rift.com/episode/7',
      ]) {
        final backend = _RefreshBackend();
        final store = DownloadUrlRefreshStore(
          backend,
          now: () => DateTime.fromMillisecondsSinceEpoch(100),
        );
        final storageUrl = cleanupUrl.contains('www.')
            ? 'https://anime-rift.com/episode/7'
            : 'https://www.anime-rift.com/episode/7';
        backend.rows[store.keyFor(storageUrl)] = <String, dynamic>{
          'providerId': _rift,
          'source': 'A',
          'trackingUrl': storageUrl,
          'updatedAtMillis': 100,
          'generation': 2,
          'ownerTaskId': 'owner-task',
          'logicalId': 'logical',
        };

        expect(
          await store.removeForOwnerGeneration(cleanupUrl, 'owner-task', 2),
          isTrue,
        );
        expect(backend.rows, isEmpty, reason: cleanupUrl);
      }
    },
  );

  test('generation cleanup deletes legacy unowned Rift alias rows', () async {
    final backend = _RefreshBackend();
    final store = DownloadUrlRefreshStore(
      backend,
      now: () => DateTime.fromMillisecondsSinceEpoch(100),
    );
    backend.rows[store.keyFor(
      'https://www.anime-rift.com/episode/7',
    )] = <String, dynamic>{
      'providerId': _rift,
      'source': 'A',
      'trackingUrl': 'https://www.anime-rift.com/episode/7',
      'updatedAtMillis': 100,
      'generation': 2,
    };

    expect(
      await store.removeForGeneration('https://anime-rift.com/episode/7', 2),
      isTrue,
    );
    expect(backend.rows, isEmpty);
  });

  test(
    'real download metadata persistence saves only safe Rift display fields',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'rift-download-privacy-',
      );
      final worker = DownloadPersistenceWorker.forDirectory(root.path);
      addTearDown(() async {
        await worker.close();
        await root.delete(recursive: true);
      });
      final storage = StorageService(downloadPersistenceWorker: worker);
      const stream = StreamResult(
        url: 'https://cdn.invalid/video?token=STREAM_SECRET',
        source: 'A',
        headers: {'Authorization': 'HEADER_SECRET'},
        drmKey: 'DRM_SECRET',
        licenseUrl: 'https://license.invalid?token=LICENSE_SECRET',
      );
      final episode = Episode(
        name: 'Episode 7',
        url: 'https://www.anime-rift.com/episode/7?token=EP_SECRET',
        season: 2,
        episode: 7,
        headers: {'Cookie': 'COOKIE_SECRET'},
        streams: [stream],
        posterUrl: 'https://images.invalid/7.jpg?token=POSTER_SECRET',
      );
      final item = MultimediaItem(
        title: 'Show',
        url: 'https://www.anime-rift.com/anime/42?token=CATALOG_SECRET',
        provider: _rift,
        posterUrl: 'https://images.invalid/poster.jpg',
        bannerUrl: 'https://images.invalid/banner.jpg?token=BANNER_SECRET',
        contentType: MultimediaContentType.anime,
        streams: [stream],
        episodes: [episode],
        headers: {'Authorization': 'ITEM_SECRET'},
        syncData: {'secret': 'SYNC_SECRET'},
        trailers: [Trailer(url: stream.url, headers: stream.headers)],
      );
      await storage.saveDownloadMetadata(
        'logical',
        item,
        episode: episode,
        trackingUrl: episode.url,
        filePath: '/downloads/local.mp4',
        logicalId: 'logical',
        taskSnapshot: {'url': stream.url, 'headers': stream.headers},
      );
      final saved = (await storage.getDownloadMetadata('logical'))!;
      expect(jsonEncode(saved), isNot(contains('SECRET')));
      final savedItem = MultimediaItem.fromJson(
        Map<String, dynamic>.from(saved['item'] as Map),
      );
      final savedEpisode = Episode.fromJson(
        Map<String, dynamic>.from(saved['episode'] as Map),
      );
      expect(savedItem.title, 'Show');
      expect(savedItem.url, 'https://anime-rift.com/anime/42');
      expect(savedItem.posterUrl, 'https://images.invalid/poster.jpg');
      expect(savedItem.provider, _rift);
      expect(savedItem.streams, isNull);
      expect(savedItem.episodes, isNull);
      expect(savedEpisode.url, 'https://anime-rift.com/episode/7');
      expect(savedEpisode.season, 2);
      expect(savedEpisode.episode, 7);
      expect(savedEpisode.headers, isNull);
      expect(saved['trackingUrl'], 'https://anime-rift.com/episode/7');
      expect(saved['filePath'], '/downloads/local.mp4');
      expect(saved['logicalId'], 'logical');
      expect(saved.containsKey('taskSnapshot'), isFalse);
      await storage.patchDownloadMetadata(
        'logical',
        trackingUrl: 'https://www.anime-rift.com/episode/7?token=PATCH_SECRET',
        taskSnapshot: {'url': stream.url, 'headers': stream.headers},
      );
      expect(
        jsonEncode(await storage.getDownloadMetadata('logical')),
        isNot(contains('SECRET')),
      );
      await storage.saveDownloadMetadata(
        'untrusted',
        item.copyWith(url: 'https://cdn.invalid/video?token=CATALOG_SECRET'),
      );
      expect(
        jsonEncode(await storage.getDownloadMetadata('untrusted')),
        isNot(contains('SECRET')),
      );
      await storage.saveDownloadMetadata(
        'native',
        item.copyWith(provider: _native),
        episode: episode,
        trackingUrl: episode.url,
      );
      expect(
        jsonEncode(await storage.getDownloadMetadata('native')),
        contains('STREAM_SECRET'),
      );
    },
  );
}

LogicalDownloadRecordV2 _record({
  required String provider,
  Map<String, Object?>? descriptor,
}) => LogicalDownloadRecordV2(
  schemaVersion: kLogicalDownloadSchemaVersionV2,
  logicalId: const DownloadLogicalId('dl_legacy_unmodified'),
  mediaId: 'https://www.anime-rift.com/anime/42',
  unitKey: 'https://www.anime-rift.com/episode/7',
  variantKey: 'sub|1080p',
  generation: 3,
  taskId: 'legacy-task',
  intent: DownloadUserIntent.paused,
  destinationPath: 'Downloads/old-partial.mp4',
  sourceDescriptor: descriptor ?? {'providerId': provider},
  updatedAtMillis: 1,
);

class _RefreshBackend implements DownloadUrlRefreshBackend {
  final rows = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> read(String key) async => rows[key];
  @override
  Future<void> write(String key, Map<String, Object?> value) async =>
      rows[key] = Map<String, dynamic>.from(value);
  @override
  Future<void> delete(String key) async {
    rows.remove(key);
  }
}
