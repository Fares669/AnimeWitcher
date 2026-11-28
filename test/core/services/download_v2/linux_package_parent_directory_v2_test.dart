import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/download_file_planner_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const _logicalId = DownloadLogicalId('dl_944e03fac6eda36b9cf5df91008563f1');
const _plannedLeaf = 'clip-944e03fac6ed.mp4';
final _show = MultimediaItem(title: 'Series', url: '/show', posterUrl: '');

void main() {
  group('Linux package video parent preparation', () {
    late Directory sandbox;
    late Directory downloads;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('aw-video-parent-');
      downloads = await Directory(p.join(sandbox.path, 'Downloads')).create();
      final original = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(downloads.path);
      addTearDown(() => PathProviderPlatform.instance = original);
      addTearDown(() => sandbox.delete(recursive: true));
    });

    Future<String> plan({String? providerId}) => downloadDestinationPathV2(
      _show,
      filename: 'clip.mp4',
      providerId: providerId,
      logicalId: _logicalId,
    );

    Future<void> prepare(
      String destination, {
      String? packagePath,
      DownloadLogicalId logicalId = _logicalId,
    }) => prepareLinuxPackageVideoParentDirectoryV2(
      destinationPath: destination,
      logicalId: logicalId,
      packageFilePath: () async => packagePath ?? destination,
    );

    test('creates only parent for native and provider scoped planned targets', () async {
      for (final providerId in [null, 'test.provider']) {
        final destination = await plan(providerId: providerId);
        final task = ParallelDownloadTask(
          url: 'https://example.invalid/no-request-made',
          filename: p.basename(destination),
          taskId: taskIdForGeneration(_logicalId, 1),
          directory: p.dirname(destination).substring(1),
          baseDirectory: BaseDirectory.root,
          chunks: 4,
        );
        final file = File(destination);
        expect(await file.parent.exists(), isFalse);
        expect(await task.filePath(), destination);
        await prepareLinuxPackageVideoParentDirectoryV2(
          destinationPath: destination,
          logicalId: _logicalId,
          packageFilePath: () => task.filePath(),
        );
        expect(p.basename(file.path), _plannedLeaf);
        expect(await file.parent.exists(), isTrue);
        expect(await file.exists(), isFalse);
        expect(await task.filePath(), destination);
      }
    });

    test('never reads or modifies an existing file or chooses a new target', () async {
      final target = File(await plan());
      await target.parent.create(recursive: true);
      await target.writeAsBytes([1, 9, 4, 4]);
      final before = await target.stat();
      await prepareLinuxPackageVideoParentDirectoryV2(
        destinationPath: target.path,
        logicalId: _logicalId,
        packageFilePath: () async => throw StateError('existing parent untouched'),
      );
      expect(await target.readAsBytes(), [1, 9, 4, 4]);
      expect((await target.stat()).modified, before.modified);
      expect(await target.parent.list().length, 1);
    });

    test('rejects off-root, sibling, relative, traversal, mismatched and legacy names', () async {
      final target = await plan();
      final outside = p.join(sandbox.path, 'outside', 'anime', 'Series', _plannedLeaf);
      await prepare(outside);
      await prepare(p.join(downloads.path, 'anime-other', 'Series', _plannedLeaf));
      await prepare('anime/Series/$_plannedLeaf');
      await prepare('${downloads.path}/anime/First/../Series/$_plannedLeaf');
      await prepare(target, packagePath: outside);
      await prepare(target, logicalId: const DownloadLogicalId('manga_non_video'));
      await prepare(p.join(p.dirname(target), 'legacy.mp4'));
      await prepare(p.join(downloads.path, 'anime', '.providers', 'not-hash', 'Series', _plannedLeaf));
      expect(await downloads.list().isEmpty, isTrue);
      expect(await Directory(p.dirname(outside)).exists(), isFalse);
    });

    test('a shaped off-root path never invokes the package path callback', () async {
      final outside = p.join(
        sandbox.path,
        'different-root',
        'anime',
        'Series',
        _plannedLeaf,
      );
      var resolvedPackagePath = false;
      await prepareLinuxPackageVideoParentDirectoryV2(
        destinationPath: outside,
        logicalId: _logicalId,
        packageFilePath: () async {
          resolvedPackagePath = true;
          return outside;
        },
      );
      expect(resolvedPackagePath, isFalse);
      expect(await Directory(p.join(sandbox.path, 'different-root')).exists(), isFalse);
      expect(await downloads.list().isEmpty, isTrue);
    });

    test('adds no directory below an existing linked component', () async {
      final outside = await Directory(p.join(sandbox.path, 'outside')).create();
      final link = await Link(p.join(downloads.path, 'anime')).create(outside.path);
      await prepare(await plan());
      expect(await outside.list().isEmpty, isTrue);
      expect(await link.target(), outside.path);
    });

    test('does not alter an obstructing file or infer a fallback root', () async {
      final blocker = await File(p.join(downloads.path, 'anime')).writeAsString('keep');
      await prepare(await plan());
      expect(await blocker.readAsString(), 'keep');
      expect(await downloads.list().length, 1);
      final target = await plan();
      await downloads.delete(recursive: true);
      await prepare(target);
      expect(await downloads.exists(), isFalse);
    });
  }, skip: !Platform.isLinux);
}

final class _Paths extends PathProviderPlatform {
  _Paths(this.downloads);
  final String downloads;

  @override
  Future<String?> getDownloadsPath() async => downloads;

  @override
  Future<String?> getApplicationDocumentsPath() async => p.dirname(downloads);
}
