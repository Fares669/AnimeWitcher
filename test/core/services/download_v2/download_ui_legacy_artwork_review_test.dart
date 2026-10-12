import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
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
}
