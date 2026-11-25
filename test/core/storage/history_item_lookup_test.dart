import 'dart:io';

import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

class _Account extends Fake implements AnimeWitcherAccountService {}

class _SnapshotStorage extends StorageService {
  _SnapshotStorage(this.rows);
  List<Map<String, dynamic>> rows;

  @override
  List<Map<String, dynamic>> getWatchHistory() => rows;
}

MultimediaItem _item(String url, [String? provider]) => MultimediaItem(
  title: 'Synthetic history',
  url: url,
  posterUrl: '',
  provider: provider,
);

Map<String, dynamic> _row(String url, String? provider, int position) => {
  'url': url,
  'provider': provider,
  'position': position,
  'duration': 300,
};

void main() {
  test('uses exact URL, provider scope, and first row precedence', () {
    const url = 'https://example.test/series';
    final storage = _SnapshotStorage([
      _row(url, 'extension-A', 25),
      _row(url, 'AnimeWitcher', 20),
      _row(url, null, 19),
      _row(url, 'extension-A', 18),
      _row(url, 'extension-B', 17),
      _row('$url/', 'AnimeWitcher', 13),
    ]);
    final repo = HistoryRepository(storage, _Account());
    final first = repo.getWatchHistoryItem(_item(url, 'extension-A'));
    expect(first?.position, 25);
    expect(repo.getWatchHistoryItem(_item(url, ' extension-A ')), same(first));
    expect(repo.getWatchHistoryItem(_item(url, 'Extension-A')), isNull);
    expect(repo.getWatchHistoryItem(_item(url, 'extension-B'))?.position, 17);
    expect(repo.getWatchHistoryItem(_item(url, 'extension-C')), isNull);
    for (final provider in [
      null,
      '',
      'AnimeWitcher',
      'Local',
      'Remote',
      'com.fares669.animewitcher.native',
    ]) {
      expect(repo.getWatchHistoryItem(_item(url, provider))?.position, 20);
    }
    expect(repo.getWatchHistoryItem(_item('$url/'))?.position, 13);
    expect(repo.getWatchHistoryItem(_item('$url?query=1')), isNull);
    expect(repo.getWatchHistory().map((h) => h.position), [
      25,
      20,
      19,
      18,
      17,
      13,
    ]);

    storage.rows = [_row(url, 'extension-B', 33)];
    expect(repo.getWatchHistoryItem(_item(url, 'extension-A')), isNull);
    expect(repo.getWatchHistoryItem(_item(url, 'extension-B'))?.position, 33);
  });

  test(
    'rechecks the latest Hive snapshot after direct history writes',
    () async {
      final dir = await Directory.systemTemp.createTemp('aw-history-lookup-');
      addTearDown(() async {
        await Hive.close();
        await dir.delete(recursive: true);
      });
      Hive.init(dir.path);
      final storage = StorageService();
      await storage.initHistory();
      final repo = HistoryRepository(storage, _Account());
      final anime = _item('https://example.test/series');
      final another = _item('https://example.test/another');
      expect(repo.getWatchHistoryItem(anime), isNull);

      await storage.saveProgress(anime, 12, 100, timestamp: 100);
      await storage.saveProgress(another, 19, 100, timestamp: 101);
      final recorded = repo.getWatchHistoryItem(anime);
      expect(recorded?.position, 12);
      expect(repo.getWatchHistoryItem(anime), same(recorded));
      expect(repo.getWatchHistory().first.item.url, another.url);
      await storage.updateHistoryItemTimestampAndPosition(
        anime.url,
        null,
        102,
        42,
      );
      expect(repo.getWatchHistoryItem(anime)?.position, 42);
      expect(repo.getWatchHistory().first.item.url, anime.url);

      await storage.markHistoryItemSynced(
        anime.url,
        accountUid: 'fake-uid',
        syncedAt: 200,
      );
      expect(repo.getWatchHistoryItem(anime)?.position, 42);
      await storage.removeFromHistory(anime.url);
      expect(repo.getWatchHistoryItem(anime), isNull);
      expect(repo.getWatchHistoryItem(another)?.position, 19);
      await storage.clearAllHistory();
      expect(repo.getWatchHistoryItem(another), isNull);
    },
  );
}
