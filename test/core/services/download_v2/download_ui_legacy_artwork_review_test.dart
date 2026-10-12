import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/download_artwork_store_v2.dart';
import 'package:animewitcher/features/library/presentation/download_episode_artwork.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../support/manga_image_fixtures.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('permanent legacy thumbnail remains readable after restart without a remote URL', () async {
    final root = await Directory.systemTemp.createTemp('aw-legacy-artwork-');
    final originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    addTearDown(() async {
      PathProviderPlatform.instance = originalPaths;
      await root.delete(recursive: true);
    });
    final saved = (await downloadedEpisodeArtworkFile('exact-task'))!;
    await saved.parent.create(recursive: true);
    await saved.writeAsBytes(tinyMangaPng);

    // A recreated UI may retain only the episode identity after an offline restart.
    final episode = Episode(name: 'Saved', url: 'episode://saved', episode: 1);
    final first = await ensureDownloadedEpisodeArtwork(taskId: 'exact-task', episode: episode);
    expect(first?.path, saved.path);
    final recreated = await ensureDownloadedEpisodeArtwork(taskId: 'exact-task', episode: episode);
    expect(recreated?.path, saved.path);
  });

  test('unverified row never copies task artwork but can read an already-owned logical thumbnail', () async {
    final root = await Directory.systemTemp.createTemp('aw-unverified-artwork-');
    final originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    addTearDown(() async {
      PathProviderPlatform.instance = originalPaths;
      await root.delete(recursive: true);
    });
    const taskId = 'unverified-legacy-task';
    const logicalId = 'unverified-logical-variant';
    final legacy = (await downloadedEpisodeArtworkFile(taskId))!;
    await legacy.parent.create(recursive: true);
    await legacy.writeAsBytes(tinyMangaJpeg);
    final episode = Episode(name: 'Saved', url: 'episode://saved', episode: 1);
    expect(await ensureDownloadedEpisodeArtwork(
      taskId: taskId, logicalId: logicalId, episode: episode, allowMetadataBackfill: false,
    ), isNull);
    expect(await downloadArtworkStoreV2.existing(logicalId, DownloadArtworkKindV2.episode), isNull);
    expect(await legacy.readAsBytes(), tinyMangaJpeg);

    // The caller positively verified this exact record before authorizing copy.
    final saved = await ensureDownloadedEpisodeArtwork(
      taskId: taskId, logicalId: logicalId, episode: episode, allowMetadataBackfill: true,
    );
    expect(saved, isNotNull);
    expect(saved!.path, isNot(legacy.path));
    expect(await ensureDownloadedEpisodeArtwork(
      taskId: taskId, logicalId: logicalId, episode: null, allowMetadataBackfill: false,
    ), isNotNull);
  });
}
