import 'dart:io';

import 'package:animewitcher/core/utils/download_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('DM-14 canonical download containment regressions', () {
    test('lookalike download roots are not treated as app-owned', () {
      expect(
        pathIsInsideAppDownloads(
          '/tmp/AnimeWitcher/Downloads-Backup/unknown-user-file.mp4',
        ),
        isFalse,
      );
      expect(
        pathIsInsideAppDownloads(
          '/tmp/PrefixAnimeWitcher/Downloads/user-file.mp4',
        ),
        isFalse,
      );
    });

    test('dot-dot escape is not treated as contained', () {
      expect(
        pathIsInsideAppDownloads(
          '/tmp/AnimeWitcher/Downloads/Series/../../outside/user-file.mp4',
        ),
        isFalse,
      );
    });

    test('mixed separators cannot disguise a dot-dot escape', () {
      expect(
        pathIsInsideAppDownloads(
          r'C:\Users\me\AnimeWitcher\Downloads\Series\..\..\outside\user-file.mp4',
        ),
        isFalse,
      );
    });

    test('cleanup does not recurse through a symlinked Downloads root', () async {
      if (Platform.isWindows) return;
      final sandbox = await Directory.systemTemp.createTemp('dm14-symlink-');
      addTearDown(() async {
        if (await sandbox.exists()) await sandbox.delete(recursive: true);
      });

      final appRoot = Directory(p.join(sandbox.path, 'app', 'AnimeWitcher'));
      final externalRoot = Directory(p.join(sandbox.path, 'external'));
      final externalSeries = Directory(p.join(externalRoot.path, 'Series'));
      await appRoot.create(recursive: true);
      await externalSeries.create(recursive: true);
      final unknown = File(p.join(externalSeries.path, 'keep-me.txt'));
      await unknown.writeAsString('not app owned', flush: true);

      final downloadsLink = Link(p.join(appRoot.path, 'Downloads'));
      await downloadsLink.create(externalRoot.path);
      final lexicalDeletedVideo = File(
        p.join(downloadsLink.path, 'Series', 'episode.mp4'),
      );

      await deleteSeriesFolderIfNoVideosRemain(lexicalDeletedVideo);

      expect(
        await unknown.exists(),
        isTrue,
        reason:
            'lexical AnimeWitcher/Downloads containment must not authorize '
            'deletion through a symlink into an external tree',
      );
    });

    test('unknown user files prevent destructive orphan cleanup', () async {
      final sandbox = await Directory.systemTemp.createTemp('dm14-unknown-');
      addTearDown(() async {
        if (await sandbox.exists()) await sandbox.delete(recursive: true);
      });

      final series = Directory(
        p.join(sandbox.path, 'AnimeWitcher', 'Downloads', 'Series'),
      );
      await series.create(recursive: true);
      final unknown = File(p.join(series.path, 'user-notes.txt'));
      await unknown.writeAsString('keep', flush: true);
      final deletedVideo = File(p.join(series.path, 'episode.mp4'));

      await deleteSeriesFolderIfNoVideosRemain(deletedVideo);

      expect(
        await unknown.exists(),
        isTrue,
        reason:
            'cleanup may remove proven app-owned manifests/parts, but must not '
            'delete arbitrary unknown user files in the same directory',
      );
    });
  });
}
