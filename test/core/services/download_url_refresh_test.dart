import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/services/download_url_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryBackend implements DownloadUrlRefreshBackend {
  final Map<String, Map<String, dynamic>> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<Map<String, dynamic>?> read(String key) async {
    final value = values[key];
    return value == null ? null : Map<String, dynamic>.from(value);
  }

  @override
  Future<void> write(String key, Map<String, Object?> value) async {
    values[key] = Map<String, dynamic>.from(value);
  }
}

class _FakeProvider extends AnimeWitcherProvider {
  _FakeProvider({
    this.sources = const [],
    this.resolved = const [],
    this.resolvedByUrl = const {},
  });

  List<StreamResult> sources;
  List<StreamResult> resolved;
  Map<String, List<StreamResult>> resolvedByUrl;
  String? lastResolvedUrl;
  String? lastSourcesUrl;
  var prepared = false;

  @override
  String get packageName => 'fake.provider';

  @override
  String get name => 'Fake';

  @override
  String get mainUrl => 'https://provider.test';

  @override
  String get version => '1';

  @override
  List<String> get languages => const ['ar'];

  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.anime};

  @override
  Future<List<MultimediaItem>> search(String query, {cancelToken}) async =>
      const [];

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => const {};

  @override
  Future<MultimediaItem> getDetails(String url) async =>
      MultimediaItem(title: 'Fake', url: url, posterUrl: '');

  @override
  Future<List<StreamResult>> loadStreamSources(String url) async {
    lastSourcesUrl = url;
    return sources;
  }

  @override
  Future<List<StreamResult>> loadStreams(String url) async {
    lastResolvedUrl = url;
    return resolvedByUrl[url] ?? resolved;
  }

  @override
  void prepareForNetworkRetry() {
    prepared = true;
  }
}

void main() {
  const saved = DownloadUrlRefreshDescriptor(
    trackingUrl: 'episode',
    providerId: 'fake.provider',
    source: 'Server A',
    quality: '1080p',
    updatedAtMillis: 1,
  );
  for (final candidate in const [
    StreamResult(
      url: 'https://cdn.test/other',
      source: 'Server B',
      quality: '1080p',
    ),
    StreamResult(
      url: 'https://cdn.test/low',
      source: 'Server A',
      quality: '720p',
    ),
    StreamResult(url: 'https://cdn.test/unknown', source: 'Server A'),
  ]) {
    test('refresh refuses incompatible candidate ${candidate.url}', () async {
      final provider = _FakeProvider(sources: [candidate]);
      final refresher = DownloadUrlRefresher(providerForId: (_) => provider);
      expect(await refresher.refresh(saved, currentUrl: 'expired'), isNull);
    });
  }

  test(
    'unresolved source may discover the exact quality during extraction',
    () async {
      final provider = _FakeProvider(
        sources: const [
          StreamResult(
            url: 'opaque',
            source: 'Server A',
            requiresResolution: true,
          ),
        ],
        resolved: const [
          StreamResult(
            url: 'https://cdn.test/new',
            source: 'Server A',
            quality: '1080p',
          ),
        ],
      );
      final refresher = DownloadUrlRefresher(providerForId: (_) => provider);
      expect(
        (await refresher.refresh(saved, currentUrl: 'expired'))?.url,
        'https://cdn.test/new',
      );
      expect(provider.lastResolvedUrl, 'opaque');
    },
  );

  test(
    'resolution cannot replace saved quality with a different encoding',
    () async {
      final provider = _FakeProvider(
        sources: const [
          StreamResult(
            url: 'opaque',
            source: 'Server A',
            requiresResolution: true,
          ),
        ],
        resolved: const [
          StreamResult(
            url: 'https://cdn.test/low',
            source: 'Server A',
            quality: '720p',
          ),
        ],
      );
      final refresher = DownloadUrlRefresher(providerForId: (_) => provider);
      expect(await refresher.refresh(saved, currentUrl: 'expired'), isNull);
    },
  );

  test(
    'incompatible refreshUrl result falls back to the saved source list',
    () async {
      final provider = _FakeProvider(
        sources: const [
          StreamResult(
            url: 'https://cdn.test/correct',
            source: 'Server A',
            quality: '1080p',
          ),
        ],
        resolved: const [
          StreamResult(
            url: 'https://cdn.test/wrong',
            source: 'Server B',
            quality: '1080p',
          ),
        ],
      );
      final refresher = DownloadUrlRefresher(providerForId: (_) => provider);
      const descriptor = DownloadUrlRefreshDescriptor(
        trackingUrl: 'episode',
        providerId: 'fake.provider',
        source: 'Server A',
        quality: '1080p',
        refreshUrl: 'stale-source',
        updatedAtMillis: 1,
      );
      expect(
        (await refresher.refresh(descriptor, currentUrl: 'expired'))?.url,
        'https://cdn.test/correct',
      );
      expect(provider.lastSourcesUrl, 'episode');
    },
  );
  test('descriptor store round trips and expires stale entries', () async {
    var now = DateTime.utc(2026, 9, 9);
    final backend = _MemoryBackend();
    final store = DownloadUrlRefreshStore(backend, now: () => now);
    final descriptor = DownloadUrlRefreshDescriptor(
      trackingUrl: 'https://provider.test/episode/1',
      providerId: 'fake.provider',
      source: 'Server A',
      quality: '1080p',
      refreshUrl: 'animewitcher-source://server-a/1',
      updatedAtMillis: now.millisecondsSinceEpoch,
    );

    await store.save(descriptor);
    expect((await store.get(descriptor.trackingUrl))?.quality, '1080p');

    now = now.add(
      kDownloadUrlRefreshDescriptorTtl + const Duration(seconds: 1),
    );
    expect(await store.get(descriptor.trackingUrl), isNull);
    expect(backend.values, isEmpty);
  });

  test('refreshUrl directly mints a fresh signed CDN URL', () async {
    final provider = _FakeProvider(
      resolved: const [
        StreamResult(
          url: 'https://cdn.test/video.mp4?token=new',
          source: 'Server A',
          quality: '1080p',
          headers: {'Referer': 'https://provider.test/'},
        ),
      ],
    );
    final refresher = DownloadUrlRefresher(
      providerForId: (id) => id == provider.packageName ? provider : null,
    );
    const descriptor = DownloadUrlRefreshDescriptor(
      trackingUrl: 'https://provider.test/episode/1',
      providerId: 'fake.provider',
      source: 'Server A',
      quality: '1080p',
      refreshUrl: 'animewitcher-source://server-a/1',
      updatedAtMillis: 1,
    );

    final result = await refresher.refresh(
      descriptor,
      currentUrl: 'https://cdn.test/video.mp4?token=old',
    );

    expect(provider.prepared, isTrue);
    expect(provider.lastResolvedUrl, descriptor.refreshUrl);
    expect(result?.url, contains('token=new'));
    expect(result?.headers['Referer'], 'https://provider.test/');
  });

  test('fresh source list wins over a stale direct refresh token', () async {
    const stale = 'https://cdn.test/video.mp4?token=old';
    const fresh = 'https://cdn.test/video.mp4?token=new';
    final provider = _FakeProvider(
      sources: const [
        StreamResult(url: fresh, source: 'Server A', quality: '1080p'),
      ],
      resolvedByUrl: const {
        'stale-source': [
          StreamResult(url: stale, source: 'Server A', quality: '1080p'),
        ],
      },
    );
    final refresher = DownloadUrlRefresher(providerForId: (_) => provider);
    const descriptor = DownloadUrlRefreshDescriptor(
      trackingUrl: 'episode',
      providerId: 'fake.provider',
      source: 'Server A',
      quality: '1080p',
      refreshUrl: 'stale-source',
      updatedAtMillis: 1,
    );

    final result = await refresher.refresh(descriptor, currentUrl: stale);

    expect(provider.lastSourcesUrl, descriptor.trackingUrl);
    expect(result?.url, fresh);
  });

  test('fallback source reload preserves source and quality', () async {
    final provider = _FakeProvider(
      sources: const [
        StreamResult(
          url: 'opaque-low',
          source: 'Server A',
          quality: '720p',
          requiresResolution: true,
        ),
        StreamResult(
          url: 'opaque-wanted',
          source: 'Server A',
          quality: '1080p',
          requiresResolution: true,
        ),
      ],
      resolved: const [
        StreamResult(
          url: 'https://cdn.test/new.mp4',
          source: 'Server A',
          quality: '1080p',
        ),
      ],
    );
    final refresher = DownloadUrlRefresher(providerForId: (_) => provider);
    const descriptor = DownloadUrlRefreshDescriptor(
      trackingUrl: 'https://provider.test/episode/1',
      providerId: 'fake.provider',
      source: 'Server A',
      quality: '1080p',
      updatedAtMillis: 1,
    );

    final result = await refresher.refresh(descriptor, currentUrl: 'expired');

    expect(provider.lastSourcesUrl, descriptor.trackingUrl);
    expect(provider.lastResolvedUrl, 'opaque-wanted');
    expect(result?.quality, '1080p');
  });

  test('missing provider cannot silently switch to another source', () async {
    const descriptor = DownloadUrlRefreshDescriptor(
      trackingUrl: 'episode',
      providerId: 'missing',
      source: 'Server A',
      updatedAtMillis: 1,
    );
    const refresher = DownloadUrlRefresher(providerForId: _noProvider);

    expect(await refresher.refresh(descriptor, currentUrl: 'expired'), isNull);
  });
}

AnimeWitcherProvider? _noProvider(String _) => null;
