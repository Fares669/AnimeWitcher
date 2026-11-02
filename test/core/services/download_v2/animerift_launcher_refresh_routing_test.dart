import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/services/download_url_refresh.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/features/details/presentation/download_launcher.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _native = 'com.fares669.animewitcher.native';
const _rift = 'com.animerift.provider';

void main() {
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
        trackingUrl: 'episode/1',
        providerId: _rift,
        source: 'Server A',
        quality: '1080p',
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
      expect(rift.sourceRequests, ['episode/1']);
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
            ? 'https://rift.invalid/episode.mp4'
            : 'https://native.invalid/episode.mp4',
        source: 'Server A',
        quality: '1080p',
      ),
    ];
  }

  @override
  Future<List<StreamResult>> loadStreams(String url) async => [];
}
