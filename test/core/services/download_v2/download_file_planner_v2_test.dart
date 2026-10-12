import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/download_file_planner_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_manifest_v2.dart';
import 'package:animewitcher/core/utils/episode_label.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  test('planned bounded episode base keeps visible uncommon quality and matches identity', () async {
    await _useTestDownloads();
    final title = List<String>.filled(100, '🧙').join();
    final base = sanitizeDownloadFileName(formatEpisodeFileName(
      episode: 12, serverName: 'الحلقة 12', title: title,
    ));
    final destination = await downloadDestinationPathV2(
      MultimediaItem(title: 'Example', url: '/anime', posterUrl: ''),
      filename: '${formatEpisodeDownloadFileName(
        episode: 12, serverName: 'الحلقة 12', title: title, quality: '1234p',
      )}.mp4',
    );
    expect(p.basename(destination), '$base (1234p).mp4');
    expect(utf8.encode(p.basename(destination)).length, lessThanOrEqualTo(212));
    expect(isDownloadedEpisodeFileName(p.basename(destination), 12,
        serverName: 'الحلقة 12', title: title), isTrue);
    expect(isDownloadedEpisodeFileName(p.basename(destination), 13,
        serverName: 'الحلقة 13', title: title), isFalse);
  });

  for (final title in <String>['.', '..', '...', '', 'a/b', r'a\b']) {
    test('anime title ${jsonEncode(title)} stays in a title folder below anime', () async {
      final temp = await _useTestDownloads();
      final destination = await downloadDestinationPathV2(
        MultimediaItem(title: title, url: '/anime', posterUrl: ''),
        filename: 'episode.mp4',
      );
      final mediaRoot = p.join(temp.path, 'anime');
      expect(p.isWithin(mediaRoot, p.normalize(p.dirname(destination))), isTrue);
      expect(p.split(p.relative(p.normalize(destination), from: mediaRoot)), hasLength(2));
      await Directory(p.dirname(destination)).create(recursive: true);
    });

    test('manga title ${jsonEncode(title)} stays in a title folder below manga', () async {
      final temp = await _useTestDownloads();
      final destination = await mangaChapterDestinationDirectoryV2(
        MultimediaItem(title: title, url: '/manga', posterUrl: ''),
        const MangaChapter(id: 'c1', mangaId: 'm1', url: '/chapter', name: '..'),
      );
      final mediaRoot = p.join(temp.path, 'manga');
      expect(p.isWithin(mediaRoot, p.normalize(destination)), isTrue);
      expect(p.split(p.relative(p.normalize(destination), from: mediaRoot)), hasLength(2));
      await Directory(destination).create(recursive: true);
    });
  }

  for (final filename in <String>[
    '', '.', '..', '../outside.mp4', 'nested/page.mp4', r'nested\page.mp4',
    '/outside.mp4', r'C:\outside.mp4',
    List<String>.filled(256, 'a').join(),
    List<String>.filled(128, 'ش').join(),
  ]) {
    test('anime planner rejects non-leaf or oversized filename ${jsonEncode(filename)}', () async {
      await _useTestDownloads();
      await expectLater(
        downloadDestinationPathV2(
          MultimediaItem(title: 'Example', url: '/anime', posterUrl: ''),
          filename: filename,
        ),
        throwsArgumentError,
      );
    });
  }

  test('Windows reserved titles create safe anime and manga folders', () async {
    await _useTestDownloads();
    final item = MultimediaItem(title: 'CON.jpg. ', url: '/media', posterUrl: '');
    final anime = await downloadDestinationPathV2(item, filename: 'episode.mp4');
    final manga = await mangaChapterDestinationDirectoryV2(
      item,
      const MangaChapter(id: 'c1', mangaId: 'm1', url: '/chapter', name: 'aux'),
    );
    expect(p.basename(p.dirname(anime)), '_CON.jpg');
    expect(p.basename(p.dirname(manga)), '_CON.jpg');
    expect(p.basename(manga), startsWith('_aux-'));
    await Directory(p.dirname(anime)).create(recursive: true);
    await Directory(manga).create(recursive: true);
  });

  test('anime planner accepts a 255-byte filename leaf', () async {
    final temp = await _useTestDownloads();
    final filename = '${List<String>.filled(251, 'a').join()}.mp4';
    final destination = await downloadDestinationPathV2(
      MultimediaItem(title: 'Example', url: '/anime', posterUrl: ''),
      filename: filename,
    );
    expect(p.basename(destination), filename);
    expect(p.isWithin(p.join(temp.path, 'anime'), destination), isTrue);
  });

  for (final title in <String>[
    List<String>.filled(128, 'ش').join(),
    List<String>.filled(100, '🧙').join(),
  ]) {
    test('long Unicode title ${title.runes.first} creates bounded anime and manga folders', () async {
      final temp = await _useTestDownloads();
      final item = MultimediaItem(title: title, url: '/media', posterUrl: '');
      final animePath = await downloadDestinationPathV2(item, filename: 'episode.mp4');
      final mangaPath = await mangaChapterDestinationDirectoryV2(
        item,
        const MangaChapter(id: 'long-label', mangaId: 'm1', url: '/chapter', name: 'Chapter'),
      );
      for (final folder in <String>[p.dirname(animePath), p.dirname(mangaPath)]) {
        final leaf = p.basename(folder);
        expect(utf8.encode(leaf).length, lessThanOrEqualTo(200));
        expect(leaf, matches(RegExp(r'-[a-f0-9]{12}$')));
        expect(leaf.runes, isNot(contains(0xfffd)));
        await Directory(folder).create(recursive: true);
      }
      expect(p.isWithin(p.join(temp.path, 'anime'), animePath), isTrue);
      expect(p.isWithin(p.join(temp.path, 'manga'), mangaPath), isTrue);
    });
  }

  test('long chapter label keeps whole Unicode code points and identity suffix', () async {
    await _useTestDownloads();
    final name = 'A${List<String>.filled(100, '🧙').join()}';
    final manga = MultimediaItem(title: 'Example', url: '/manga', posterUrl: '');
    final first = await mangaChapterDestinationDirectoryV2(
      manga, MangaChapter(id: 'first', mangaId: 'm1', url: '/first', name: name),
    );
    final second = await mangaChapterDestinationDirectoryV2(
      manga, MangaChapter(id: 'second', mangaId: 'm1', url: '/second', name: name),
    );
    expect(first, isNot(second));
    for (final destination in <String>[first, second]) {
      final leaf = p.basename(destination);
      expect(utf8.encode(leaf).length, lessThanOrEqualTo(213));
      expect(leaf.runes, isNot(contains(0xfffd)));
      expect(utf8.decode(utf8.encode(leaf)), leaf);
      expect(leaf, matches(RegExp(r'-[a-f0-9]{12}-[a-f0-9]{12}$')));
      await Directory(destination).create(recursive: true);
    }
  });

  for (final oldTitle in <String>['Foo.', List<String>.filled(110, 'ش').join()]) {
    for (final hasIdentitySuffix in <bool>[false, true]) {
      test('matching manifest preserves old title ${oldTitle.runes.first} identity suffix $hasIdentitySuffix', () async {
        final temp = await _useTestDownloads();
        const chapter = MangaChapter(id: 'c1', mangaId: 'm1', url: '/chapter', name: 'Chapter');
        final chapterName = hasIdentitySuffix ? 'Chapter-${logicalDownloadIdForMangaChapter(mangaId: 'm1', chapterId: 'c1').value.substring('manga_'.length, 'manga_'.length + 12)}' : 'Chapter';
        final oldPath = p.join(temp.path, 'manga', oldTitle, chapterName);
        await MangaChapterManifestV2(
          version: MangaChapterManifestV2.currentVersion,
          mangaId: 'm1', chapterId: 'c1', pageCount: 1,
          completedIndexes: const <int>{0}, isComplete: true,
        ).writeTo(Directory(oldPath));
        final planned = await mangaChapterDestinationDirectoryV2(
          MultimediaItem(title: oldTitle, url: '/manga', posterUrl: ''), chapter,
        );
        expect(planned, oldPath);
        expect(p.isWithin(p.join(temp.path, 'manga'), p.normalize(planned)), isTrue);
      });
    }
  }

  test('matching manifest keeps prior 90-unit identity-suffixed chapter directory', () async {
    final temp = await _useTestDownloads();
    final name = List<String>.filled(120, 'a').join();
    final chapter = MangaChapter(id: 'c1', mangaId: 'm1', url: '/chapter', name: name);
    final suffix = logicalDownloadIdForMangaChapter(mangaId: 'm1', chapterId: 'c1').value.substring('manga_'.length, 'manga_'.length + 12);
    final oldPath = p.join(temp.path, 'manga', 'Example', '${name.substring(0, 90)}-$suffix');
    final page = File(p.join(oldPath, '0001.webp'));
    await page.create(recursive: true);
    await page.writeAsBytes(<int>[1, 2, 3]);
    await MangaChapterManifestV2(
      version: MangaChapterManifestV2.currentVersion,
      mangaId: 'm1', chapterId: 'c1', pageCount: 1,
      completedIndexes: const <int>{0}, isComplete: true,
    ).writeTo(Directory(oldPath));
    expect(await mangaChapterDestinationDirectoryV2(
      MultimediaItem(title: 'Example', url: '/manga', posterUrl: ''), chapter,
    ), oldPath);
    expect(await page.readAsBytes(), <int>[1, 2, 3]);
  });

  test('historical split emoji chapter reuses its actual UTF-8 legacy directory', () async {
    final temp = await _useTestDownloads();
    final name = 'A${List<String>.filled(100, '🧙').join()}';
    final chapter = MangaChapter(id: 'c1', mangaId: 'm1', url: '/chapter', name: name);
    final suffix = logicalDownloadIdForMangaChapter(mangaId: 'm1', chapterId: 'c1').value.substring('manga_'.length, 'manga_'.length + 12);
    final oldLeaf = '${name.substring(0, 90)}-$suffix';
    final oldRawPath = p.join(temp.path, 'manga', 'Example', oldLeaf);
    final actualPath = p.join(temp.path, 'manga', 'Example', utf8.decode(utf8.encode(oldLeaf)));
    expect(oldRawPath, isNot(actualPath));
    expect(p.basename(actualPath).runes, contains(0xfffd));
    final page = File(p.join(actualPath, '0001.webp'));
    await page.create(recursive: true);
    await page.writeAsBytes(<int>[1, 2, 3], flush: true);
    await MangaChapterManifestV2(
      version: MangaChapterManifestV2.currentVersion,
      mangaId: 'm1', chapterId: 'c1', pageCount: 1,
      completedIndexes: const <int>{0}, isComplete: true,
    ).writeTo(Directory(actualPath));
    expect(await Directory(actualPath).exists(), isTrue);
    final planned = await mangaChapterDestinationDirectoryV2(
      MultimediaItem(title: 'Example', url: '/manga', posterUrl: ''), chapter,
    );
    expect(planned, actualPath);
    expect(p.isWithin(p.join(temp.path, 'manga'), p.normalize(planned)), isTrue);
    expect(await File(p.join(actualPath, '0001.webp')).readAsBytes(), <int>[1, 2, 3]);
  });

  test('legacy path lookup never adopts a dot-title manifest outside manga', () async {
    final temp = await _useTestDownloads();
    final unsafeLegacy = Directory(p.join(temp.path, 'Chapter'));
    await MangaChapterManifestV2(
      version: MangaChapterManifestV2.currentVersion,
      mangaId: 'm1', chapterId: 'c1', pageCount: 1,
      completedIndexes: const <int>{0}, isComplete: true,
    ).writeTo(unsafeLegacy);
    final planned = await mangaChapterDestinationDirectoryV2(
      MultimediaItem(title: '..', url: '/manga', posterUrl: ''),
      const MangaChapter(id: 'c1', mangaId: 'm1', url: '/chapter', name: 'Chapter'),
    );
    expect(planned, isNot(unsafeLegacy.path));
    expect(p.isWithin(p.join(temp.path, 'manga'), p.normalize(planned)), isTrue);
  });

  test('chapters sharing a display number have distinct destinations', () async {
    final temp = await Directory.systemTemp.createTemp('aw-chapter-identity-');
    addTearDown(() => temp.delete(recursive: true));
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(temp.path);
    addTearDown(() => PathProviderPlatform.instance = previous);

    final manga = MultimediaItem(title: 'Example', url: '/manga', posterUrl: '');
    const first = MangaChapter(
      id: 'chapter-first', mangaId: 'm1', url: '/chapter/first',
      name: 'Chapter one', number: 1,
    );
    const second = MangaChapter(
      id: 'chapter-second', mangaId: 'm1', url: '/chapter/second',
      name: 'Chapter one alt', number: 1,
    );

    final firstPath = await mangaChapterDestinationDirectoryV2(manga, first);
    final secondPath = await mangaChapterDestinationDirectoryV2(manga, second);
    expect(firstPath, isNot(secondPath));
    expect(p.basename(firstPath), contains('الفصل 1'));
    expect(p.basename(secondPath), contains('الفصل 1'));
  });

  test('existing chapter manifest keeps its legacy destination', () async {
    final temp = await Directory.systemTemp.createTemp('aw-chapter-legacy-');
    addTearDown(() => temp.delete(recursive: true));
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(temp.path);
    addTearDown(() => PathProviderPlatform.instance = previous);

    final manga = MultimediaItem(title: 'Example', url: '/manga', posterUrl: '');
    const chapter = MangaChapter(
      id: 'chapter-first', mangaId: 'm1', url: '/chapter/first',
      name: 'Chapter one', number: 1,
    );
    final oldPath = p.join(temp.path, 'manga', 'Example', 'الفصل 1');
    await MangaChapterManifestV2(
      version: MangaChapterManifestV2.currentVersion,
      mangaId: 'm1',
      chapterId: 'chapter-first',
      pageCount: 1,
      completedIndexes: const <int>{0},
      isComplete: true,
    ).writeTo(Directory(oldPath));

    expect(await mangaChapterDestinationDirectoryV2(manga, chapter), oldPath);
  });
}

final class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getDownloadsPath() async => path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

Future<Directory> _useTestDownloads() async {
  final temp = await Directory.systemTemp.createTemp('aw-safe-planner-');
  addTearDown(() => temp.delete(recursive: true));
  final previous = PathProviderPlatform.instance;
  PathProviderPlatform.instance = _TestPaths(temp.path);
  addTearDown(() => PathProviderPlatform.instance = previous);
  return temp;
}
