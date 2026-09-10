import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/features/details/presentation/stream_source_prefetch.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _episodeUrl = 'https://example.test/anime/ep-12';

/// Answers [loadStreamSources] from a script, so a test can say "fail once,
/// then work" and count how many times the provider was actually reached.
class _ScriptedProvider extends AnimeWitcherProvider {
  _ScriptedProvider(this._script);

  /// One entry per expected call: null means throw.
  final List<List<StreamResult>?> _script;

  final List<String> calls = <String>[];

  @override
  Future<List<StreamResult>> loadStreamSources(String url) async {
    calls.add(url);
    final index = calls.length - 1;
    final result = index < _script.length ? _script[index] : _script.last;
    if (result == null) {
      throw StateError('provider unreachable');
    }
    return result;
  }

  @override
  Future<List<StreamResult>> loadStreams(String url) async {
    // The cache never resolves a playback url; only the list is its business.
    throw UnimplementedError('not part of the prefetch contract');
  }

  @override
  String get packageName => 'fake.prefetch';

  @override
  String get name => 'Fake';

  @override
  String get mainUrl => 'https://example.test';

  @override
  String get version => '1';

  @override
  List<String> get languages => const <String>['ar'];

  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.anime};

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async {
    return const <String, List<MultimediaItem>>{};
  }

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    return const <MultimediaItem>[];
  }

  @override
  Future<MultimediaItem> getDetails(String url) async {
    return MultimediaItem(title: 'Details', url: url, posterUrl: '');
  }
}

List<StreamResult> _sources(String url) => <StreamResult>[
  StreamResult(url: url, source: 'Fake'),
];

void main() {
  test('serves a fetched list without asking the provider twice', () async {
    final provider = _ScriptedProvider(<List<StreamResult>?>[
      _sources('https://cdn.test/a.m3u8'),
    ]);
    final cache = StreamSourcePrefetch();

    expect((await cache.sources(provider, _episodeUrl)).single.url,
        'https://cdn.test/a.m3u8');
    expect((await cache.sources(provider, _episodeUrl)).single.url,
        'https://cdn.test/a.m3u8');
    expect(provider.calls, hasLength(1));
  });

  test('a warm fetch is handed to the request that follows it', () async {
    final provider = _ScriptedProvider(<List<StreamResult>?>[
      _sources('https://cdn.test/warm.m3u8'),
    ]);
    final cache = StreamSourcePrefetch();

    cache.warm(provider, _episodeUrl);
    expect((await cache.sources(provider, _episodeUrl)).single.url,
        'https://cdn.test/warm.m3u8');
    expect(provider.calls, hasLength(1), reason: 'the warm fetch was reused');
  });

  test('a failure is not remembered, so trying again really tries again',
      () async {
    // The picker asks for an episode's sources while the connection is
    // briefly down, then the viewer taps the episode again — which is what
    // anyone does. That second tap has to reach the provider.
    final provider = _ScriptedProvider(<List<StreamResult>?>[
      null,
      _sources('https://cdn.test/second.m3u8'),
    ]);
    final cache = StreamSourcePrefetch();

    await expectLater(
      cache.sources(provider, _episodeUrl),
      throwsA(isA<StateError>()),
    );
    expect(provider.calls, hasLength(1));

    expect((await cache.sources(provider, _episodeUrl)).single.url,
        'https://cdn.test/second.m3u8');
    expect(provider.calls, hasLength(2),
        reason: 'the retry must reach the provider, not replay the failure');
  });

  test('a failed warm does not poison the request that follows', () async {
    final provider = _ScriptedProvider(<List<StreamResult>?>[
      null,
      _sources('https://cdn.test/after-warm.m3u8'),
    ]);
    final cache = StreamSourcePrefetch();

    cache.warm(provider, _episodeUrl);
    // Let the warm fail and be forgotten before the viewer asks.
    await Future<void>.delayed(Duration.zero);

    expect((await cache.sources(provider, _episodeUrl)).single.url,
        'https://cdn.test/after-warm.m3u8');
    expect(provider.calls, hasLength(2));
  });

  test('clearing drops what was cached for another anime', () async {
    final provider = _ScriptedProvider(<List<StreamResult>?>[
      _sources('https://cdn.test/one.m3u8'),
      _sources('https://cdn.test/two.m3u8'),
    ]);
    final cache = StreamSourcePrefetch();

    await cache.sources(provider, _episodeUrl);
    cache.clear();
    expect((await cache.sources(provider, _episodeUrl)).single.url,
        'https://cdn.test/two.m3u8');
    expect(provider.calls, hasLength(2));
  });

  test('an empty url is not a request', () async {
    final provider = _ScriptedProvider(<List<StreamResult>?>[
      _sources('https://cdn.test/never.m3u8'),
    ]);
    final cache = StreamSourcePrefetch();

    cache.warm(provider, '   ');
    await Future<void>.delayed(Duration.zero);
    expect(provider.calls, isEmpty);
  });
}
