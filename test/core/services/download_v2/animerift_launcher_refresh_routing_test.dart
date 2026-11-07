import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/services/download_url_refresh.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/features/details/presentation/download_launcher.dart';
import 'package:animewitcher/core/storage/anime_rift_account_scope.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _native = 'com.fares669.animewitcher.native';
const _rift = 'com.animerift.provider';
const _riftEpisode = 'https://anime-rift.com/anime/a/episode/e';
const _riftDownloadSource =
    'https://anime-rift.com/anime/a/episode/e/source/h/quality/1080p/download/n/1';

void main() {
  test('download renewal restores linked account before checking descriptor ownership', () async {
    AnimeRiftLocalAccountScope.activate('account-A');
    final accountHash = AnimeRiftLocalAccountScope.accountHash;
    AnimeRiftLocalAccountScope.reset();
    addTearDown(AnimeRiftLocalAccountScope.reset);

    final provider = AnimeRiftProvider(client: _RestoringRiftApi());
    final renewed =
        await DownloadUrlRefresher(
          providerForId: (id) => id == _rift ? provider : null,
        ).refresh(
          DownloadUrlRefreshDescriptor(
            trackingUrl: _riftEpisode,
            providerId: _rift,
            source: 'CR2',
            quality: '1080p',
            refreshUrl: _riftDownloadSource,
            accountHash: accountHash,
            updatedAtMillis: 1,
          ),
          currentUrl: 'https://cdn.example/expired.mp4',
        );

    expect(renewed?.url, 'https://cdn.example/renewed.mp4');
    expect(AnimeRiftLocalAccountScope.accountHash, accountHash);
  });

  test(
    'download selection restores the Rift account before capturing its scope',
    () async {
      AnimeRiftLocalAccountScope.reset();
      addTearDown(AnimeRiftLocalAccountScope.reset);
      final provider = AnimeRiftProvider(client: _RestoringRiftApi());

      expect(AnimeRiftLocalAccountScope.accountHash, isNull);
      final hash = await downloadAccountHashForProviderV2(provider);
      expect(hash, isNotNull);
      expect(hash, AnimeRiftLocalAccountScope.accountHash);
      expect(
        await downloadAccountHashForProviderV2(_RefreshProvider(_native)),
        isNull,
      );
    },
  );

  test('batch skips existing episodes only within their original provider', () {
    final records = <LogicalDownloadRecordV2>[
      _record('legacy', null, intent: DownloadUserIntent.active),
      _record('native', _native, completed: true),
      _record('rift', _rift, intent: DownloadUserIntent.paused),
      _record('failed', _rift, intent: DownloadUserIntent.failed),
      _record('other-show', _rift, mediaId: 'different-show'),
      _record('manga', _rift, mediaKind: DownloadMediaKind.mangaChapter),
    ];

    expect(
      existingBatchEpisodeKeysForProviderV2(
        records,
        mediaId: 'show',
        providerId: _native,
      ),
      {'legacy', 'native'},
    );
    expect(
      existingBatchEpisodeKeysForProviderV2(
        records,
        mediaId: 'show',
        providerId: _rift,
      ),
      {'rift'},
    );
    expect(
      existingBatchEpisodeKeysForProviderV2(
        records,
        mediaId: 'show',
        providerId: 'another.provider',
      ),
      {'legacy'},
    );
  });

  test(
    'URL refresh resolves the original provider after selection changes',
    () async {
      final native = _RefreshProvider(_native);
      final rift = _RefreshProvider(_rift);
      final requestedProviders = <String>[];
      final refresher = DownloadUrlRefresher(
        providerForId: (id) {
          requestedProviders.add(id);
          return {_native: native, _rift: rift}[id];
        },
      );
      const descriptor = DownloadUrlRefreshDescriptor(
        trackingUrl: _riftEpisode,
        providerId: _rift,
        source: 'Server A',
        quality: '1080p',
        refreshUrl: _riftDownloadSource,
        updatedAtMillis: 1234,
      );
      final restored = DownloadUrlRefreshDescriptor.fromJson(
        descriptor.toJson(),
      )!;

      final result = await refresher.refresh(
        restored,
        currentUrl: 'https://expired.invalid/video.mp4',
      );

      expect(requestedProviders, [_rift]);
      expect(native.sourceRequests, isEmpty);
      expect(rift.sourceRequests, [_riftEpisode]);
      expect(result?.url, 'https://rift.invalid/episode.mp4');
      expect(restored.providerId, _rift);
    },
  );

  test(
    'URL refresh does not fall back when the original provider is gone',
    () async {
      final native = _RefreshProvider(_native);
      final refresher = DownloadUrlRefresher(
        providerForId: (id) => id == _native ? native : null,
      );
      const descriptor = DownloadUrlRefreshDescriptor(
        trackingUrl: 'episode/1',
        providerId: _rift,
        source: 'Server A',
        updatedAtMillis: 1234,
      );

      expect(
        await refresher.refresh(descriptor, currentUrl: 'expired'),
        isNull,
      );
      expect(native.sourceRequests, isEmpty);
    },
  );
}

class _RestoringRiftApi extends AnimeRiftApiClient {
  @override
  Future<bool> restoreAccountSession() async {
    AnimeRiftLocalAccountScope.activate('account-A');
    return true;
  }

  @override
  Future<Map<String, dynamic>> request(
    String path,
    String scope, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) async {
    switch (path) {
      case 'library/episodes/a':
        return {
          'items': [
            {'\u005fid': 'e', 'episode_number': 1},
          ],
        };
      case 'library/episode/sources':
        return {
          'offline_mode_enabled': true,
          'items': [
            {
              '_id': 'h',
              'provider': 'cr2',
              'server_name': 'CR2',
              'qualities': ['1080p'],
            },
          ],
          'configs': [
            {'server_key': 'cr2', 'priority': 1},
          ],
        };
      case 'library/episode/source/can_play':
        return {'sessionId': 'session'};
      case 'library/episode/source/direct_link':
        return {
          'url_response': true,
          'videoUrl': 'https://cdn.example/renewed.mp4',
        };
      default:
        throw StateError('Unexpected API route');
    }
  }
}

LogicalDownloadRecordV2 _record(
  String episode,
  String? providerId, {
  String mediaId = 'show',
  DownloadUserIntent intent = DownloadUserIntent.active,
  bool completed = false,
  DownloadMediaKind mediaKind = DownloadMediaKind.videoEpisode,
}) => LogicalDownloadRecordV2(
  schemaVersion: kLogicalDownloadSchemaVersionV2,
  logicalId: logicalDownloadIdFor(
    animeId: mediaId,
    episodeKey: episode,
    variantKey: '1080p',
    providerId: providerId,
  ),
  mediaId: mediaId,
  unitKey: episode,
  variantKey: '1080p',
  mediaKind: mediaKind,
  generation: 1,
  taskId: episode,
  intent: intent,
  destinationPath: 'Downloads/$episode.mp4',
  sourceDescriptor: {if (providerId != null) 'providerId': providerId},
  updatedAtMillis: 1234,
  completedAtMillis: completed ? 1234 : null,
);

class _RefreshProvider extends AnimeWitcherProvider {
  _RefreshProvider(this.packageName);

  @override
  final String packageName;
  final List<String> sourceRequests = [];

  @override
  String get name => packageName;
  @override
  String get mainUrl => 'https://example.invalid';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['ar'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.anime};

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => {};
  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => [];
  @override
  Future<MultimediaItem> getDetails(String url) async =>
      MultimediaItem(title: 'Show', url: url, posterUrl: '');
  @override
  Future<List<StreamResult>> loadStreamSources(String url) async {
    sourceRequests.add(url);
    return [
      StreamResult(
        url: packageName == _rift
            ? _riftDownloadSource
            : 'https://native.invalid/episode.mp4',
        source: 'Server A',
        quality: '1080p',
        requiresResolution: packageName == _rift,
      ),
    ];
  }

  @override
  Future<List<StreamResult>> loadStreams(String url) async => [];

  @override
  Future<List<StreamResult>> loadDownloadStreams(String url) async =>
      packageName == _rift && url == _riftDownloadSource
      ? [
          StreamResult(
            url: 'https://rift.invalid/episode.mp4',
            source: 'Server A',
            quality: '1080p',
            refreshUrl: _riftDownloadSource,
          ),
        ]
      : [];
}
