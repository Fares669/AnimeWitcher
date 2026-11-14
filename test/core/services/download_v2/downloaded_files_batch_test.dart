import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/anime_rift_account_scope.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/features/details/presentation/downloaded_file_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _item = MultimediaItem(title: 'Show', url: 'show://one', posterUrl: '');
Episode _episode(int number) =>
    Episode(name: '$number', url: 'episode://$number');

void main() {
  test('older absent batch cannot overwrite a newer completed file', () async {
    final root = await Directory.systemTemp.createTemp('aw-file-race-');
    addTearDown(() => root.delete(recursive: true));
    final gate = Completer<void>();
    final store = _CountingStore(firstScanGate: gate);
    final container = ProviderContainer(
      overrides: [logicalDownloadStoreV2Provider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final files = container.read(downloadedFilesProvider.notifier);
    final episode = _episode(1);
    final older = files.checkFile(_item, episode: episode);
    await store.firstScanStarted.future;
    final file = await File('${root.path}/one.mp4').writeAsBytes([1, 2]);
    await store.put(_record(file.path));
    await files.checkFile(_item, episode: episode);
    final key = downloadedFileKey(_item, episode: episode);
    expect(container.read(downloadedFilesProvider)[key]?.path, file.path);
    gate.complete();
    await older;
    expect(container.read(downloadedFilesProvider)[key]?.path, file.path);
  });

  test('queued checks cannot publish after an account switch', () async {
    final root = await Directory.systemTemp.createTemp('aw-file-scope-');
    addTearDown(() => root.delete(recursive: true));
    addTearDown(AnimeRiftLocalAccountScope.reset);
    final file = await File('${root.path}/one.mp4').writeAsBytes([1, 2]);
    final store = _CountingStore();
    await store.put(_record(file.path));
    final container = ProviderContainer(
      overrides: [logicalDownloadStoreV2Provider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    AnimeRiftLocalAccountScope.activate('alice');
    final files = container.read(downloadedFilesProvider.notifier);
    final checking = files.checkFile(_item, episode: _episode(1));
    AnimeRiftLocalAccountScope.activate('bob');
    await checking;
    expect(container.read(downloadedFilesProvider), isEmpty);
  });

  test('100 absent rows share one scan and publish no map changes', () async {
    final store = _CountingStore();
    final container = ProviderContainer(
      overrides: [logicalDownloadStoreV2Provider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    var changes = 0;
    container.listen(downloadedFilesProvider, (_, _) => changes++);
    final files = container.read(downloadedFilesProvider.notifier);
    await Future.wait([
      for (var i = 0; i < 100; i++)
        files.checkFile(_item, episode: _episode(i)),
    ]);
    expect(store.scans, 1);
    expect(changes, 0);
    expect(container.read(downloadedFilesProvider), isEmpty);
  });

  test(
    'batch detects later completed, external bytes and deleted records',
    () async {
      final root = await Directory.systemTemp.createTemp('aw-file-batch-');
      addTearDown(() => root.delete(recursive: true));
      final store = _CountingStore();
      final container = ProviderContainer(
        overrides: [logicalDownloadStoreV2Provider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      var changes = 0;
      container.listen(downloadedFilesProvider, (_, _) => changes++);
      final files = container.read(downloadedFilesProvider.notifier);
      final episode = _episode(1);
      final key = downloadedFileKey(_item, episode: episode);
      await files.checkFile(_item, episode: episode);
      final file = File('${root.path}/one.mp4');
      final record = _record(file.path);
      await store.put(record);
      await files.checkFile(_item, episode: episode);
      expect(container.read(downloadedFilesProvider)[key], isNull);
      await file.writeAsBytes([1, 2]);
      await files.checkFile(_item, episode: episode);
      expect(container.read(downloadedFilesProvider)[key]?.path, file.path);
      final changedAfterCompletion = changes;
      await Future.wait(
        List.generate(100, (_) => files.checkFile(_item, episode: episode)),
      );
      expect(changes, changedAfterCompletion);
      await store.remove(record.logicalId);
      await files.checkFile(_item, episode: episode);
      expect(container.read(downloadedFilesProvider)[key], isNull);
      expect(changes, changedAfterCompletion + 1);
      await store.put(record);
      await file.delete();
      await files.checkFile(_item, episode: episode);
      expect(container.read(downloadedFilesProvider)[key], isNull);
    },
  );
}

LogicalDownloadRecordV2 _record(String path) => LogicalDownloadRecordV2(
  schemaVersion: kLogicalDownloadSchemaVersionV2,
  logicalId: const DownloadLogicalId('one'),
  mediaId: 'show://one',
  unitKey: 'episode://1',
  variantKey: 'sub',
  generation: 1,
  taskId: 'task-one',
  intent: DownloadUserIntent.active,
  destinationPath: path,
  sourceDescriptor: const {},
  updatedAtMillis: 1,
  completedAtMillis: 1,
  expectedBytes: 2,
);

class _CountingStore implements LogicalDownloadStoreV2 {
  _CountingStore({this.firstScanGate});
  final Completer<void>? firstScanGate;
  final firstScanStarted = Completer<void>();
  final delegate = InMemoryLogicalDownloadStoreV2();
  int scans = 0;
  @override
  Future<List<LogicalDownloadRecordV2>> all() async {
    final scan = ++scans;
    final records = await delegate.all();
    if (scan == 1) {
      firstScanStarted.complete();
      await firstScanGate?.future;
    }
    return records;
  }

  @override
  Future<LogicalDownloadRecordV2?> get(DownloadLogicalId id) =>
      delegate.get(id);
  @override
  Future<void> put(LogicalDownloadRecordV2 record) => delegate.put(record);
  @override
  Future<void> remove(DownloadLogicalId id) => delegate.remove(id);
  @override
  Future<LogicalDownloadRecordV2?> mutate(
    DownloadLogicalId id,
    LogicalDownloadRecordV2? Function(LogicalDownloadRecordV2?) change,
  ) => delegate.mutate(id, change);
}
