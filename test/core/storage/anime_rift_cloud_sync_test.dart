import 'dart:async';

import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/storage/anime_rift_account_scope.dart';
import 'package:animewitcher/core/storage/anime_rift_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';

class _Reader implements AnimeRiftCloudAccountReader {
  bool restored = true;
  final calls = <String>[];
  Future<Map<String, dynamic>> Function()? overviewRequest;
  Future<Map<String, dynamic>> Function()? favoriteRequest;
  Future<Map<String, dynamic>> Function()? latestRequest;

  @override
  Future<bool> restoreAccountSession() async {
    calls.add('restore');
    return restored;
  }

  @override
  Future<Map<String, dynamic>> fetchMyListOverview() {
    calls.add('overview');
    return overviewRequest?.call() ??
        Future.value({
          'items': {
            'my_list_favorites': '3',
            'my_list_currently_watching': 2,
            'favorite_characters_count': 1,
            'random_private_field': 'never expose me',
          },
        });
  }

  @override
  Future<Map<String, dynamic>> fetchFavoriteAnime() {
    calls.add('favorites');
    return favoriteRequest?.call() ??
        Future.value({
          'items': [
            {'unknownServerRow': 'secret row'},
          ],
        });
  }

  @override
  Future<Map<String, dynamic>> fetchMyList(String category) async {
    calls.add('list:$category');
    return <String, dynamic>{'items': <Object>[]};
  }

  @override
  Future<Map<String, dynamic>> fetchWatchHistoryLatest() {
    calls.add('latest');
    return latestRequest?.call() ??
        Future.value(<String, dynamic>{
          'items': {'unverifiedRow': 1},
        });
  }

  @override
  Future<Map<String, dynamic>> fetchWatchHistoryFull() async {
    calls.add('full');
    return <String, dynamic>{'items': null};
  }
}

void main() {
  tearDown(AnimeRiftLocalAccountScope.reset);

  test(
    'guest and failed restore never read private account resources',
    () async {
      final guest = _Reader();
      await expectLater(
        AnimeRiftCloudSync(guest).inspect(),
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );
      expect(guest.calls, ['restore']);

      AnimeRiftLocalAccountScope.activate('A');
      final expired = _Reader()..restored = false;
      await expectLater(
        AnimeRiftCloudSync(expired).inspect(),
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );
      expect(expired.calls, ['restore']);
    },
  );

  test(
    'only confirmed totals and opaque shape diagnostics are exposed',
    () async {
      AnimeRiftLocalAccountScope.activate('A');
      final reader = _Reader();
      final snapshot = await AnimeRiftCloudSync(reader).inspect();

      expect(reader.calls, ['restore', 'overview', 'favorites', 'latest']);
      expect(snapshot.belongsToCurrentAccount, isTrue);
      expect(snapshot.overviewCounts, {
        'my_list_favorites': 3,
        'my_list_currently_watching': 2,
        'favorite_characters_count': 1,
      });
      expect(
        snapshot.resources['my_list/overview']!.shape,
        AnimeRiftCloudResponseShape.itemsMap,
      );
      final favorites = snapshot.resources['favorite/anime/all']!;
      expect(favorites.shape, AnimeRiftCloudResponseShape.itemsList);
      expect(favorites.returnedListLength, 1);
      expect(
        snapshot.resources['watch_history/latest']!.shape,
        AnimeRiftCloudResponseShape.itemsMap,
      );
      expect(snapshot.toString(), isNot(contains('secret row')));
      expect(() => snapshot.overviewCounts.clear(), throwsUnsupportedError);
      expect(() => snapshot.resources.clear(), throwsUnsupportedError);
    },
  );

  test('optional full history and per-list reads require opt-in', () async {
    AnimeRiftLocalAccountScope.activate('A');
    final reader = _Reader();
    final snapshot = await AnimeRiftCloudSync(reader)
        .inspect(includeLists: true, includeFullWatchHistory: true);

    for (final category in AnimeRiftCloudSync.listCategories) {
      expect(reader.calls, contains('list:$category'));
      expect(
        snapshot.resources['my_list/all:$category']!.returnedListLength,
        0,
      );
    }
    expect(reader.calls, contains('full'));
    expect(
      snapshot.resources['watch_history/full']!.shape,
      AnimeRiftCloudResponseShape.unrecognized,
    );
  });

  test(
    'offline and malformed responses never masquerade as empty lists',
    () async {
      AnimeRiftLocalAccountScope.activate('A');
      final reader = _Reader();
      reader.overviewRequest = () async => <String, dynamic>{'items': null};
      reader.favoriteRequest = () async =>
          throw const AnimeRiftAccessUnavailable();
      reader.latestRequest = () async => <String, dynamic>{
        'items': 'bad schema',
      };
      final snapshot = await AnimeRiftCloudSync(reader).inspect();

      expect(snapshot.overviewCounts, isEmpty);
      expect(
        snapshot.resources['my_list/overview']!.shape,
        AnimeRiftCloudResponseShape.unrecognized,
      );
      expect(
        snapshot.resources['favorite/anime/all']!.shape,
        AnimeRiftCloudResponseShape.unavailable,
      );
      expect(
        snapshot.resources['favorite/anime/all']!.returnedListLength,
        isNull,
      );
      expect(
        snapshot.resources['watch_history/latest']!.shape,
        AnimeRiftCloudResponseShape.unrecognized,
      );
    },
  );

  test(
    'session change during cloud request rejects the entire inspection',
    () async {
      AnimeRiftLocalAccountScope.activate('A');
      final pending = Completer<Map<String, dynamic>>();
      final reader = _Reader()..overviewRequest = () => pending.future;
      final inspection = AnimeRiftCloudSync(reader).inspect();
      final checked = expectLater(
        inspection,
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );
      await Future<void>.delayed(Duration.zero);
      AnimeRiftLocalAccountScope.activate('B');
      pending.complete({
        'items': {'my_list_favorites': 300},
      });
      await checked;

      expect(reader.calls, ['restore', 'overview']);
    },
  );

  test(
    'a completed snapshot cannot be read after an A/B/guest switch',
    () async {
      AnimeRiftLocalAccountScope.activate('A');
      final snapshot = await AnimeRiftCloudSync(_Reader()).inspect();

      AnimeRiftLocalAccountScope.activate('B');
      expect(snapshot.belongsToCurrentAccount, isFalse);
      expect(
        () => snapshot.overviewCounts,
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );
      expect(
        () => snapshot.resources,
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );

      AnimeRiftLocalAccountScope.reset();
      expect(
        () => snapshot.overviewCounts,
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );
    },
  );

  test(
    'server authentication failure aborts instead of returning stale data',
    () async {
      AnimeRiftLocalAccountScope.activate('A');
      final reader = _Reader()
        ..favoriteRequest = () async =>
            throw const AnimeRiftAuthenticationRequired(statusCode: 401);
      await expectLater(
        AnimeRiftCloudSync(reader).inspect(),
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );
      expect(reader.calls, ['restore', 'overview', 'favorites']);
    },
  );

  test('raw HTTP 403 errors cannot be treated as offline data', () async {
    AnimeRiftLocalAccountScope.activate('A');
    final reader = _Reader();
    reader.latestRequest = () async =>
        throw const AnimeRiftAccessUnavailable(statusCode: 403);
    await expectLater(
      AnimeRiftCloudSync(reader).inspect(),
      throwsA(isA<AnimeRiftAuthenticationRequired>()),
    );
  });
}
