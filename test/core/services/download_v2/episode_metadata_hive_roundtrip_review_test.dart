import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/download_persistence_worker.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/utils/episode_label.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'storage startup recovers unreadable download metadata in its worker',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'aw-metadata-recovery-',
      );
      final paths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(directory.path);
      final worker = DownloadPersistenceWorker.forDirectory(
        directory.path,
        documentsDirectory: directory.path,
      );
      try {
        Hive.init(directory.path);
        Hive.registerAdapter(_UnreadableMetadataAdapter());
        final existing = await Hive.openBox<dynamic>(
          StorageService.kDownloadMetadataBox,
        );
        await existing.put('obsolete-adapter', _UnreadableMetadata());
        await existing.close();

        final metadataFile = File(
          '${directory.path}/${StorageService.kDownloadMetadataBox}.hive',
        );
        final originalBytes = metadataFile.readAsBytesSync();
        await expectLater(
          worker.run('hive.open', [StorageService.kDownloadMetadataBox]),
          throwsA(isA<HiveError>()),
        );
        expect(metadataFile.readAsBytesSync(), originalBytes);
        final storage = StorageService(downloadPersistenceWorker: worker);
        await storage.init();
        expect(await storage.getAllDownloadMetadata(), isEmpty);
        final item = MultimediaItem(
          title: 'Recovered',
          url: 'show',
          posterUrl: '',
        );
        await storage.saveDownloadMetadata('new-download', item);
        expect(
          (await storage.getDownloadMetadata('new-download'))?['item'],
          item.toJson(),
        );
      } finally {
        await worker.close();
        await Hive.close();
        Hive.resetAdapters();
        PathProviderPlatform.instance = paths;
        directory.deleteSync(recursive: true);
      }
    },
  );

  test('actual saved download metadata and Hive history roundtrip original labels and raw numbers', () async {
    final directory = await Directory.systemTemp.createTemp(
      'aw-original-episode-',
    );
    final paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    try {
      final storage = StorageService();
      await storage.init();
      final item = MultimediaItem(
        title: 'Show',
        url: 'https://animewitcher.com/watch/show',
        posterUrl: '',
        contentType: MultimediaContentType.anime,
      );
      const label = '  الحلقة ٢.٥: عودة / الجزء؟  ';
      for (final raw in <String?>['٢', '٢.٥', '02.50', null]) {
        final source = Episode.fromJson({
          'name': 'العودة الأصلية؟',
          'url': 'show|ep2',
          'episode': 2,
          'serverName': label,
          if (raw != null) 'serverNumber': raw,
        });
        await storage.saveDownloadMetadata('selected', item, episode: source);
        final saved = await storage.getDownloadMetadata('selected');
        final episode = Episode.fromJson(
          Map<String, dynamic>.from(saved!['episode'] as Map),
        );
        expect(episode.serverName, label);
        expect(episode.serverNumber, raw);
        expect(episode.episode, 2);
        await storage.saveContinueWatchingProgress(
          item,
          30000,
          100000,
          lastEpisodeUrl: episode.url,
          episode: episode.episode,
          episodeTitle: episodeTitleForStorage(
            episode: episode.episode,
            title: episode.name,
            serverName: episode.serverName,
          ),
          episodeServerName: episode.serverName,
          episodeServerNumber: episode.serverNumber,
        );
        await storage.recordHistoryOpen(
          item,
          lastEpisodeUrl: episode.url,
          episode: episode.episode,
          episodeTitle: episode.name,
          episodeServerName: episode.serverName,
          episodeServerNumber: episode.serverNumber,
        );
        for (final row in [
          storage.getContinueWatching().single,
          storage.getWatchHistory().single,
        ]) {
          final history = HistoryItem.fromMap(row);
          expect(history.episodeTitle, episode.name);
          expect(history.episodeServerName, label);
          expect(history.episodeServerNumber, raw);
          expect(
            continueWatchingPrimaryLabel(
              episode: history.episode,
              episodeServerName: history.episodeServerName,
              episodeServerNumber: history.episodeServerNumber,
            ),
            label,
          );
        }
      }
      await (await DownloadPersistenceWorker.application()).close();
      await Hive.close();
      final reopened = StorageService();
      await reopened.init();
      final history = HistoryItem.fromMap(
        reopened.getContinueWatching().single,
      );
      expect(history.episodeServerName, label);
      expect(history.episodeServerNumber, isNull);
    } finally {
      await (await DownloadPersistenceWorker.application()).close();
      await Hive.close();
      PathProviderPlatform.instance = paths;
      await directory.delete(recursive: true);
    }
  });

  test('raw number fallback retains supplied digits and never invents missing metadata', () {
    for (final raw in ['٢', '٢.٥', '02.50']) {
      expect(
        continueWatchingPrimaryLabel(episode: 2, episodeServerNumber: raw),
        raw,
      );
    }
    for (final absent in <Object?>[
      null,
      '',
      'unknown',
      {},
      [],
      double.infinity,
    ]) {
      expect(rawEpisodeNumberForDisplay(absent), isNull);
    }
    final legacy = Episode(name: '', url: 'show|ep2', episode: 2);
    expect(legacy.toJson().containsKey('serverNumber'), isFalse);
    expect(legacy.serverNumber, isNull);
  });
}

final class _UnreadableMetadata {}

final class _UnreadableMetadataAdapter
    extends TypeAdapter<_UnreadableMetadata> {
  @override
  int get typeId => 223;

  @override
  _UnreadableMetadata read(BinaryReader reader) => _UnreadableMetadata();

  @override
  void write(BinaryWriter writer, _UnreadableMetadata value) {}
}
