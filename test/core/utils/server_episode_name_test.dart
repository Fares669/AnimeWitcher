import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/utils/episode_label.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_storage_service.dart';

void main() {
  const serverNames = [
    '  الحلقة ٢.٥  ',
    '\tEpisode 0002\n',
    '  قسمت ۰۰۲  ',
    ' الحلقة الخاصة: العودة / الجزء؟ ',
    '  مترجم  ',
    '  Story &amp; <special>  ',
  ];

  for (final serverName in serverNames) {
    test('preserves the complete server name $serverName', () {
      final label = resolveEpisodeLabel(
        episode: 999,
        serverName: serverName,
        isFinal: true,
      );
      expect(label.primary, serverName);
      expect(label.full, serverName);
      expect(label.secondary, isEmpty);
      expect(
        formatEpisodeLabel(
          episode: 999,
          serverName: serverName,
          title: 'A separate creative title',
          isFinal: true,
        ),
        serverName,
      );
      expect(
        formatEpisodePrimaryLabel(
          episode: 999,
          serverName: serverName,
          isFinal: true,
        ),
        serverName,
      );
      expect(latestEpisodesPosterBadge(serverName), serverName);
      final latestItem = MultimediaItem(
        title: 'Show',
        url: 'show',
        posterUrl: '',
        episodeBadge: serverName,
      );
      expect(
        MultimediaItem.fromJson(latestItem.toJson()).episodeBadge,
        serverName,
      );
      expect(
        continueWatchingPrimaryLabel(
          episode: 999,
          episodeServerName: serverName,
        ),
        serverName,
      );
      expect(
        episodeTitleForStorage(episode: 999, serverName: serverName),
        serverName,
      );
      final episode = Episode(
        name: '',
        url: 'show|ep2',
        episode: 999,
        serverName: serverName,
      );
      expect(
        Episode.fromJson(episode.toJson())
            .copyWith(posterUrl: 'artwork')
            .serverName,
        serverName,
      );
    });
  }

  test('retains the missing-name fallback for legacy episodes', () {
    expect(formatEpisodePrimaryLabel(episode: 12), 'حلقة 12');
    expect(
      formatEpisodePrimaryLabel(episode: 12, isFinal: true, serverName: '  '),
      'حلقة 12 والأخيرة',
    );
    expect(formatEpisodePrimaryLabel(episode: 0), isEmpty);
    expect(latestEpisodesPosterBadge('  '), isNull);
    expect(continueWatchingPrimaryLabel(episode: 12), 'حلقة 12');
    for (final badge in <Object?>[null, '', '  ', <String, String>{}, <String>[]]) {
      expect(MultimediaItem.fromJson({'episodeBadge': badge}).episodeBadge, isNull);
    }
  });

  test('native provider retains server names before display or persistence', () async {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: options.uri.path.endsWith('/episodes')
                    ? {
                        'documents': [
                          for (final (index, name) in serverNames.indexed)
                            {
                              'name':
                                  'projects/test/databases/(default)/documents/anime_list/show/episodes/ep$index',
                              'fields': {
                                'name': {'stringValue': name},
                                'episode_number': {'integerValue': '$index'},
                              },
                            },
                        ],
                      }
                    : <String, dynamic>{},
              ),
            );
          },
        ),
      );
    addTearDown(dio.close);
    final provider = AnimeWitcherNativeProvider(
      dio,
      SettingsRepository(MemoryStorageService()),
    );
    final episodes = await provider.getEpisodes(
      'https://animewitcher.com/watch/show',
    );
    expect(episodes.map((episode) => episode.serverName), serverNames);
  });
}
