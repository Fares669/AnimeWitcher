import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/services/download_v2/anime_rift_download_metadata_v2.dart';
import 'package:dio/dio.dart';
import 'package:animewitcher/core/services/download_url_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

const episodeUrl = 'https://anime-rift.com/anime/anime42/episode/ep7';

class StreamFixture extends AnimeRiftApiClient {
  StreamFixture()
    : super(
        config: const AnimeRiftConfig(
          firebaseApiKey: 'fixture',
          firebaseAppId: 'fixture',
          signingKey: 'fixture',
        ),
      );
  final calls = <({String path, Map<String, dynamic>? body})>[];
  bool requireDownloadAuth = false;
  String? authRequiredHost;
  bool denyPlayback = false;
  String? unavailableHost;
  @override
  Future<Map<String, dynamic>> request(
    String path,
    String scope, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) async {
    calls.add((path: path, body: body));
    if (path == 'library/episodes/anime42')
      return {
        'items': [
          {'_id': 'ep7', 'episode_number': 7},
        ],
      };
    if (path == 'library/episode/sources')
      return {
        'items': [
          {
            '_id': 'host1',
            'server_name': 'CR2',
            'provider': 'cr2',
            'sub_title': 'ar_sub',
            'qualities': ['720P', '1080P'],
          },
          {
            '_id': 'watchonly',
            'server_name': 'BBZ',
            'provider': 'bkbz',
            'sub_title': 'ar_sub',
            'qualities': ['360P'],
          },
          {
            '_id': 'premium',
            'server_name': 'PREMIUM',
            'provider': 'idrivee2',
            'qualities': ['1080P'],
          },
        ],
        'offline_mode_enabled': true,
        'configs': [
          {
            'server_key': 'cr2',
            'priority': 1,
            'in_app_download_disabled': false,
          },
          {
            'server_key': 'bkbz',
            'priority': 2,
            'in_app_download_disabled': true,
          },
          {'server_key': 'idrivee2', 'is_premium': true},
        ],
      };
    if (path.endsWith('/can_play')) {
      if ((body?['is_download'] == true && requireDownloadAuth) ||
          body?['hostId'] == authRequiredHost)
        return {'require_auth': true};
      if (body?['hostId'] == unavailableHost) return {'can_play': false};
      if (denyPlayback) return {'can_play': false, 'requires_ad': true};
      return {
        'sessionId': 'ephemeral-session',
        'claimed': false,
        'can_continue_on_empty_fill_rate': true,
      };
    }
    if (path.endsWith('/direct_link'))
      return {
        'url_response': true,
        'videoUrl': 'https://cdn.example/video.mp4?token=ephemeral',
        'tracks': [
          {
            'file': 'https://cdn.example/ar.vtt',
            'label': 'العربية',
            'language': 'ar',
          },
        ],
        'http_headers': {
          'Referer': 'https://player.example/',
          'Host': 'unexpected.example',
          'x-invalid': 'bad\r\nheader',
        },
      };
    throw StateError('Unexpected fixture operation');
  }
}

void main() {
  test(
    'automatic playback falls back but an explicit server stays selected',
    () async {
      final api = StreamFixture()..unavailableHost = 'host1';
      final provider = AnimeRiftProvider(client: api);
      final selected = (await provider.loadStreamSources(episodeUrl)).first;
      await expectLater(
        provider.loadStreams(selected.url),
        throwsA(isA<AnimeRiftPlaybackUnavailable>()),
      );
      expect(
        api.calls.where((c) => c.path.endsWith('/can_play')),
        hasLength(1),
      );
      api.calls.clear();
      final fallback = await provider.loadStreams(episodeUrl);
      expect(fallback.single.source, contains('BBZ'));
      expect(
        api.calls.where((c) => c.path.endsWith('/can_play')),
        hasLength(3),
      );
    },
  );

  test(
    'V2 renewal after restart preserves the source and download entitlement',
    () async {
      final api = StreamFixture();
      final provider = AnimeRiftProvider(client: api);
      final selected = (await provider.loadDownloadStreamSources(episodeUrl))
          .first;
      final descriptor = DownloadUrlRefreshDescriptor.fromJson(
        DownloadUrlRefreshDescriptor(
          trackingUrl: episodeUrl,
          providerId: provider.packageName,
          source: selected.source,
          quality: selected.quality,
          refreshUrl: selected.url,
          updatedAtMillis: 1,
        ).toJson(),
      )!;
      expect(descriptor.refreshUrl, selected.url);
      final refresher = DownloadUrlRefresher(
        providerForId: (id) => id == provider.packageName ? provider : null,
      );
      final result = await refresher.refresh(
        descriptor,
        currentUrl: 'https://cdn.example/expired.mp4',
      );
      expect(result?.url, 'https://cdn.example/video.mp4?token=ephemeral');
      final availability = api.calls
          .where((c) => c.path.endsWith('/can_play'))
          .single;
      expect(availability.body!['is_download'], isTrue);
      expect(availability.body!['event_name'], 'download_episode_unlocked');
    },
  );

  test(
    'source selection is deferred and omits premium and forbidden downloads',
    () async {
      final api = StreamFixture();
      final provider = AnimeRiftProvider(client: api);
      final play = await provider.loadStreamSources(episodeUrl);
      expect(play, hasLength(3));
      expect(play.every((s) => s.requiresResolution), isTrue);
      expect(
        play.map((s) => s.quality),
        containsAll(['720P', '1080P', '360P']),
      );
      expect(api.calls.any((c) => c.path.endsWith('/can_play')), isFalse);
      final download = await provider.loadDownloadStreamSources(episodeUrl);
      expect(download, hasLength(2));
      expect(download.every((s) => !s.source.contains('BBZ')), isTrue);
      for (final source in [...play, ...download]) {
        expect(source.url, isNot(contains('?')));
        expect(animeRiftDownloadTrackingIdentityV2(source.url), source.url);
      }
    },
  );
  test('selected source resolves qualities, subtitles and bounded headers without ad claims', () async {
    final api = StreamFixture();
    final provider = AnimeRiftProvider(client: api);
    final sources = await provider.loadStreamSources(episodeUrl);
    final selected = sources.firstWhere((s) => s.quality == '1080P');
    final streams = await provider.loadStreams(selected.url);
    expect(streams, hasLength(1));
    final stream = streams.single;
    expect(stream.url, 'https://cdn.example/video.mp4?token=ephemeral');
    expect(stream.refreshUrl, selected.url);
    expect(stream.requiresResolution, isFalse);
    expect(stream.subtitles!.single.lang, 'ar');
    expect(stream.headers!['Referer'], 'https://player.example/');
    expect(stream.headers!.keys, isNot(contains('Host')));
    expect(stream.headers!.keys, isNot(contains('x-invalid')));
    expect(api.calls.any((c) => c.path.contains('ads_manager')), isFalse);
    expect(
      api.calls
          .firstWhere((c) => c.path.endsWith('/can_play'))
          .body!['is_download'],
      isFalse,
    );
  });
  test(
    'download uses download entitlement even if passed a playback token',
    () async {
      final api = StreamFixture()..requireDownloadAuth = true;
      final provider = AnimeRiftProvider(client: api);
      final token = (await provider.loadStreamSources(episodeUrl)).first.url;
      await expectLater(
        provider.loadDownloadStreams(token),
        throwsA(predicate((e) => e.toString().contains('تسجيل الدخول'))),
      );
      expect(api.calls.last.path, endsWith('/can_play'));
      expect(api.calls.last.body!['is_download'], isTrue);
      expect(api.calls.last.body!['event_name'], 'download_episode_unlocked');
    },
  );
  test(
    'access gates do not request a direct link or fabricate an advertisement',
    () async {
      final api = StreamFixture()..denyPlayback = true;
      final provider = AnimeRiftProvider(client: api);
      final source = (await provider.loadStreamSources(episodeUrl)).first;
      await expectLater(
        provider.loadStreams(source.url),
        throwsA(isA<AnimeRiftAccessUnavailable>()),
      );
      expect(api.calls.any((c) => c.path.endsWith('/direct_link')), isFalse);
      expect(api.calls.any((c) => c.path.contains('ads_manager')), isFalse);
    },
  );
  test('untrusted source URLs fail before contacting the provider', () async {
    final api = StreamFixture();
    final provider = AnimeRiftProvider(client: api);
    for (final url in [
      'https://attacker.example/anime/a/episode/b',
      'file:///tmp/video',
      'https://anime-rift.com/anime/a/episode/b?secret=1',
    ]) {
      await expectLater(
        provider.loadStreams(url),
        throwsA(isA<AnimeRiftAccessUnavailable>()),
      );
    }
    expect(api.calls, isEmpty);
  });

  test('automatic playback skips a login-gated host for a guest-accessible fallback', () async {
    final api = StreamFixture()..authRequiredHost = 'host1';
    final provider = AnimeRiftProvider(client: api);
    final automatic = await provider.loadStreams(episodeUrl);
    expect(automatic.single.source, contains('BBZ'));
    expect(
      api.calls.where((c) => c.path.endsWith('/direct_link')),
      hasLength(1),
    );
    final first = (await provider.loadStreamSources(episodeUrl)).first;
    await expectLater(
      provider.loadStreams(first.url),
      throwsA(isA<AnimeRiftAuthenticationRequired>()),
    );
  });

  test('automatic download preserves the authentication error when every source is gated', () async {
    final api = StreamFixture()..requireDownloadAuth = true;
    final provider = AnimeRiftProvider(client: api);
    await expectLater(
      provider.loadDownloadStreams(episodeUrl),
      throwsA(isA<AnimeRiftAuthenticationRequired>()),
    );
    expect(
      api.calls.where((c) => c.path.endsWith('/direct_link')),
      isEmpty,
    );
    expect(
      api.calls.where((c) => c.path.endsWith('/can_play')),
      hasLength(2),
    );
  });
}
