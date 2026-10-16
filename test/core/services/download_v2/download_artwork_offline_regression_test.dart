import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/network/poster_cache.dart';
import 'package:animewitcher/core/services/download_v2/download_artwork_store_v2.dart';
import 'package:animewitcher/features/library/presentation/download_episode_artwork.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../support/manga_image_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final originalPaths = PathProviderPlatform.instance;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('aw-offline-artwork-');
    PathProviderPlatform.instance = _Paths(root.path);
  });
  setUp(() async {
    await DefaultCacheManager().emptyCache();
    await posterCacheManager.emptyCache();
  });
  tearDownAll(() async {
    await DefaultCacheManager().dispose();
    await posterCacheManager.dispose();
    PathProviderPlatform.instance = originalPaths;
    await root.delete(recursive: true);
  });

  test(
    'displayed poster cache becomes permanent without upstream Internet',
    () async {
      const url = 'https://example.test/displayed-poster.png';
      await posterCacheManager.putFile(url, tinyMangaPng, fileExtension: 'png');
      var requests = 0;
      final artwork = DownloadArtworkStoreV2(
        supportDirectory: () async => root,
        fetchBytes: (_) async {
          requests++;
          throw const SocketException('router has no upstream Internet');
        },
      );
      final retained = await artwork.ensure(
        logicalId: 'poster-cache',
        kind: DownloadArtworkKindV2.poster,
        url: url,
      );
      expect(retained, isNotNull);
      expect(requests, 0);
      expect(await retained!.readAsBytes(), tinyMangaPng);
      await posterCacheManager.emptyCache();
      final restarted = DownloadArtworkStoreV2(
        supportDirectory: () async => root,
        fetchBytes: (_) async =>
            throw StateError('retained image must be local'),
      );
      expect(
        await restarted.ensure(
          logicalId: 'poster-cache',
          kind: DownloadArtworkKindV2.poster,
        ),
        isNotNull,
      );
      await restarted.delete('poster-cache');
      expect(await retained.exists(), isFalse);
    },
  );

  test(
    'invalid default cache entry does not hide a valid displayed poster',
    () async {
      const url = 'https://example.test/two-namespaces.png';
      await DefaultCacheManager().putFile(
        url,
        Uint8List.fromList([60, 104, 116, 109, 108, 62]),
      );
      await posterCacheManager.putFile(url, tinyMangaPng, fileExtension: 'png');
      final artwork = DownloadArtworkStoreV2(
        supportDirectory: () async => root,
        fetchBytes: (_) async =>
            throw StateError('cache bytes are already present'),
      );
      final retained = await artwork.ensure(
        logicalId: 'invalid-default',
        kind: DownloadArtworkKindV2.poster,
        url: url,
      );
      expect(retained, isNotNull);
      expect(await retained!.readAsBytes(), tinyMangaPng);
    },
  );

  test(
    'missing serialized episode image retains banner and poster fallbacks',
    () async {
      const banner = 'https://example.test/fallback-banner.png';
      const poster = 'https://example.test/fallback-poster.jpg';
      await DefaultCacheManager().putFile(
        banner,
        tinyMangaPng,
        fileExtension: 'png',
      );
      await posterCacheManager.putFile(
        poster,
        tinyMangaJpeg,
        fileExtension: 'jpg',
      );
      await retainDownloadedArtwork(
        logicalId: 'missing-episode',
        taskId: 'task-missing-episode',
        item: _item(banner: banner, poster: poster),
        episode: _episode('undefined'),
      );
      await DefaultCacheManager().emptyCache();
      await posterCacheManager.emptyCache();
      final episode = await downloadArtworkStoreV2.existing(
        'missing-episode',
        DownloadArtworkKindV2.episode,
      );
      final savedPoster = await downloadArtworkStoreV2.existing(
        'missing-episode',
        DownloadArtworkKindV2.poster,
      );
      expect(episode, isNotNull);
      expect(savedPoster, isNotNull);
      expect(await episode!.readAsBytes(), tinyMangaPng);
      expect(await savedPoster!.readAsBytes(), tinyMangaJpeg);
    },
  );

  test(
    'all cached candidates precede an unavailable valid thumbnail URL',
    () async {
      const banner = 'https://example.test/cached-banner.png';
      await DefaultCacheManager().putFile(
        banner,
        tinyMangaPng,
        fileExtension: 'png',
      );
      await retainDownloadedArtwork(
        logicalId: 'cached-before-network',
        taskId: 'task-cached-before-network',
        item: _item(banner: banner),
        episode: _episode('https://unavailable.example.test/still.png'),
      );
      final retained = await downloadArtworkStoreV2.existing(
        'cached-before-network',
        DownloadArtworkKindV2.episode,
      );
      expect(retained, isNotNull);
      expect(await retained!.readAsBytes(), tinyMangaPng);
    },
  );

  for (final invalid in ['404', 'html']) {
    test(
      'failed $invalid thumbnail falls through to a valid remote banner',
      () async {
        final previousHttp = HttpOverrides.current;
        HttpOverrides.global = null;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final requested = <String>[];
        final serving = server.listen((request) async {
          requested.add(request.uri.path);
          if (request.uri.path == '/banner') {
            request.response.add(tinyMangaPng);
          } else if (invalid == '404') {
            request.response.statusCode = HttpStatus.notFound;
          } else {
            request.response.write('<html>router login page</html>');
          }
          await request.response.close();
        });
        try {
          final base = 'http://127.0.0.1:${server.port}';
          await retainDownloadedArtwork(
            logicalId: 'remote-$invalid',
            taskId: 'task-remote-$invalid',
            item: _item(banner: '$base/banner'),
            episode: _episode('$base/$invalid'),
          );
          final retained = await downloadArtworkStoreV2.existing(
            'remote-$invalid',
            DownloadArtworkKindV2.episode,
          );
          expect(retained, isNotNull);
          expect(await retained!.readAsBytes(), tinyMangaPng);
          expect(requested, ['/$invalid', '/banner']);
        } finally {
          await serving.cancel();
          await server.close(force: true);
          HttpOverrides.global = previousHttp;
        }
      },
    );
  }

  test(
    'later fallback metadata cannot replace an already retained still',
    () async {
      const still = 'https://example.test/canonical-still.jpg';
      const banner = 'https://example.test/later-banner.png';
      await DefaultCacheManager().putFile(
        still,
        tinyMangaJpeg,
        fileExtension: 'jpg',
      );
      final saved = await downloadArtworkStoreV2.ensure(
        logicalId: 'canonical-still',
        kind: DownloadArtworkKindV2.episode,
        url: still,
      );
      expect(saved, isNotNull);
      await DefaultCacheManager().removeFile(still);
      await posterCacheManager.putFile(
        banner,
        tinyMangaPng,
        fileExtension: 'png',
      );
      await retainDownloadedArtwork(
        logicalId: 'canonical-still',
        taskId: 'task-canonical-still',
        item: _item(banner: banner),
        episode: _episode(null),
      );
      expect(await saved!.readAsBytes(), tinyMangaJpeg);
    },
  );
}

MultimediaItem _item({String? banner, String poster = ''}) => MultimediaItem(
  title: 'Saved anime',
  url: 'show',
  posterUrl: poster,
  bannerUrl: banner,
);
Episode _episode(String? image) =>
    Episode(name: 'Episode 1', url: 'episode', posterUrl: image);

final class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}
