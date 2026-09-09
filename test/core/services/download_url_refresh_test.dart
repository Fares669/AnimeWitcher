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
  _FakeProvider({this.sources = const [], this.resolved = const []});

  List<StreamResult> sources;
  List<StreamResult> resolved;
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
  Future<MultimediaItem> getDetails(String url) async => MultimediaItem(
    title: 'Fake',
    url: url,
    posterUrl: '',
  );

  @override
  Future<List<StreamResult>> loadStreamSources(String url) async {
    lastSourcesUrl = url;
    return sources;
  }

  @override
  Future<List<StreamResult>> loadStreams(String url) async {
    lastResolvedUrl = url;
    return resolved;
  }

  @override
  void prepareForNetworkRetry() {
    prepared = true;
  }
}

void main() {
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

    now = now.add(kDownloadUrlRefreshDescriptorTtl + const Duration(seconds: 1));
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
