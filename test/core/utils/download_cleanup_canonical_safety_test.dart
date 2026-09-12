import 'dart:io';

import 'package:animewitcher/core/utils/download_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('app download containment is segment-aware and traversal-safe', () {
    final root = p.join(
      Directory.systemTemp.path,
      'scope',
      'AnimeWitcher',
      'Downloads',
    );

    expect(pathIsInsideAppDownloads(p.join(root, 'Show', 'ep.mp4')), isTrue);
    expect(pathIsAppDownloadsRoot(root), isTrue);
    expect(
      pathIsInsideAppDownloads(
        p.join(Directory.systemTemp.path, 'scope', 'AnimeWitcher', 'DownloadsBackup', 'ep.mp4'),
      ),
      isFalse,
    );
    expect(
      pathIsInsideAppDownloads(p.join(root, '..', 'Private', 'ep.mp4')),
      isFalse,
    );
  });

  test('series cleanup never recursively deletes unknown user content', () async {
    final sandbox = await Directory.systemTemp.createTemp('aw-cleanup-safety-');
    addTearDown(() async {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });
    final series = Directory(
      p.join(sandbox.path, 'AnimeWitcher', 'Downloads', 'Show'),
    );
    await series.create(recursive: true);
    final unknown = File(p.join(series.path, 'notes.txt'));
    await unknown.writeAsString('keep me');

    final deletedEpisode = File(
      p.join(series.path, 'Season 1', 'episode 01.mp4'),
    );
    await deleteSeriesFolderIfNoVideosRemain(deletedEpisode);

    expect(await unknown.exists(), isTrue);
    expect(await series.exists(), isTrue);
  });

  test('series cleanup may remove only known leftover download artifacts', () async {
    final sandbox = await Directory.systemTemp.createTemp('aw-cleanup-owned-');
    addTearDown(() async {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });
    final series = Directory(
      p.join(sandbox.path, 'AnimeWitcher', 'Downloads', 'Show'),
    );
    final season = Directory(p.join(series.path, 'Season 1'));
    await season.create(recursive: true);
    await File(p.join(season.path, 'episode 01.mp4.part')).writeAsBytes([1, 2, 3]);
    await File(p.join(season.path, 'manifest.json.tmp')).writeAsString('{}');

    await deleteSeriesFolderIfNoVideosRemain(
      File(p.join(season.path, 'episode 01.mp4')),
    );

    expect(await series.exists(), isFalse);
  });

  test('series cleanup does not traverse a symlink escape', () async {
    if (Platform.isWindows) return;
    final sandbox = await Directory.systemTemp.createTemp('aw-cleanup-link-');
    addTearDown(() async {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });
    final downloads = Directory(
      p.join(sandbox.path, 'AnimeWitcher', 'Downloads'),
    );
    await downloads.create(recursive: true);
    final outside = Directory(p.join(sandbox.path, 'outside'));
    await outside.create();
    final unknown = File(p.join(outside.path, 'notes.txt'));
    await unknown.writeAsString('outside');
    final link = Link(p.join(downloads.path, 'Show'));
    await link.create(outside.path);

    await deleteSeriesFolderIfNoVideosRemain(
      File(p.join(link.path, 'Season 1', 'episode 01.mp4')),
    );

    expect(await link.exists(), isTrue);
    expect(await unknown.exists(), isTrue);
  });
}
