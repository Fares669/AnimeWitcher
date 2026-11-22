import 'dart:convert';

import 'package:animewitcher/core/extensions/provider_stream_exception.dart';
import 'package:animewitcher/core/extensions/providers/anime3rb_playback.dart';
import 'package:animewitcher/core/extensions/providers/anime3rb_transport.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubTransport implements Anime3rbTransport {
  _StubTransport(this.onGet, {this.onPost});

  final Future<Anime3rbHttpResponse> Function(
    Uri uri,
    Map<String, String> headers,
    bool followRedirects,
  )
  onGet;
  final Future<Anime3rbHttpResponse> Function(Uri uri, Object? body)? onPost;

  @override
  Future<Anime3rbHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    bool followRedirects = true,
    bool inspectMedia = false,
    CancelToken? cancelToken,
    String operation = 'get',
  }) => onGet(uri, headers, followRedirects);

  @override
  Future<Anime3rbHttpResponse> post(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'post',
  }) => onPost != null
      ? onPost!(uri, body)
      : Future.value(const Anime3rbHttpResponse(statusCode: 404, body: ''));

  @override
  Future<Anime3rbHttpResponse> put(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'put',
  }) => Future.value(const Anime3rbHttpResponse(statusCode: 404, body: ''));

  @override
  Future<Anime3rbHttpResponse> delete(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'delete',
  }) => Future.value(const Anime3rbHttpResponse(statusCode: 404, body: ''));

  @override
  Future<String> fetchHtml(
    Uri uri, {
    Map<String, String> headers = const {},
    CancelToken? cancelToken,
    String operation = 'catalog',
  }) async {
    final resp = await get(uri, headers: headers, operation: operation);
    if (resp.statusCode == 429) throw const Anime3rbRateLimitException();
    if (resp.isCloudflareChallenge) {
      throw Anime3rbBrowserRequiredException('cf', watchUrl: uri);
    }
    return resp.body;
  }

  @override
  void close({bool force = false}) {}
}

String _episodeHtml({
  String playerUrl =
      'https://video.vid3rb.com/player/uuid-1?token=t1&expires=999',
}) {
  final snapshot = const HtmlEscape().convert(
    jsonEncode({
      'data': {'video_url': playerUrl, 'video_source': 'src1'},
    }),
  );
  return '''
<html>
<head><meta name="csrf-token" content="csrf123"></head>
<body>
  <script src="/livewire/livewire.min.js" data-csrf="csrf123" data-update-uri="https://anime3rb.com/livewire-daa1cdb1/update"></script>
  <div wire:name="video.show-video" wire:snapshot="$snapshot">
    <button data-video-source="src1"><span title="ترجمة Crunchyroll">ترجمة Crunchyroll</span></button>
    <button data-video-source="src2"><span title="ترجمة بديلة">ترجمة بديلة</span></button>
  </div>
  <div wire:key="download.src1">
    <h3><small>ترجمة Crunchyroll</small></h3>
    <div>
      <div>
        <label>جودة عالية بحجم أقل [1080p HEVC]</label>
        <a href="https://anime3rb.com/download/hevc-id?expires=999&signature=sig1">تحميل</a>
      </div>
      <a href="https://anime3rb.com/hevc">اعرف المزيد</a>
    </div>
    <div>
      <div>
        <label>جودة عالية [1080p]</label>
        <a href="https://anime3rb.com/download/free-1080?expires=999&signature=sig2">تحميل</a>
      </div>
    </div>
  </div>
</body>
</html>
''';
}

void main() {
  test('loadSources separates watch servers and skips premium HEVC download', () async {
    final resolver = Anime3rbPlaybackResolver(
      _StubTransport((uri, _, _) async {
        return Anime3rbHttpResponse(statusCode: 200, body: _episodeHtml());
      }),
    );

    final playSources = await resolver.loadSources(
      'https://anime3rb.com/episode/one-piece/1180',
      forDownload: false,
    );
    expect(playSources.map((s) => s.source).toList(), [
      'Vid3rb · ترجمة Crunchyroll [HD]',
      'Vid3rb · ترجمة بديلة [HD]',
      'Anime3rb مباشر · ترجمة Crunchyroll [1080p]',
    ]);
    expect(playSources.every((s) => s.requiresResolution), isTrue);

    final dlSources = await resolver.loadSources(
      'https://anime3rb.com/episode/one-piece/1180',
      forDownload: true,
    );
    expect(
      dlSources.first.source,
      'Anime3rb مباشر · ترجمة Crunchyroll [1080p]',
    );
    expect(
      dlSources.any((s) => s.source.contains('HEVC')),
      isFalse,
    );
  });

  test('resolveStreams parses inline video_sources and skips premium entries', () async {
    final resolver = Anime3rbPlaybackResolver(
      _StubTransport((uri, headers, _) async {
        if (uri.path.startsWith('/episode/')) {
          return Anime3rbHttpResponse(statusCode: 200, body: _episodeHtml());
        }
        expect(headers['Referer'], 'https://anime3rb.com/');
        return const Anime3rbHttpResponse(
          statusCode: 200,
          body: '''
<script>
var video_sources = [
  {"src": "https://cdn.vid3rb.com/prem.mp4", "label": "1080p Premium", "premium": true},
  {"src": "https://cdn.vid3rb.com/480.mp4", "label": "480p", "premium": false},
  {"src": "https://cdn.vid3rb.com/1080.mp4", "label": "1080p", "premium": false}
];
</script>
''',
        );
      }),
    );

    final sources = await resolver.loadSources(
      'https://anime3rb.com/episode/one-piece/1180',
      forDownload: false,
    );
    final streams = await resolver.resolveStreams(
      sources.first.url,
      forDownload: false,
    );
    expect(streams.map((s) => s.url), [
      'https://cdn.vid3rb.com/1080.mp4',
      'https://cdn.vid3rb.com/480.mp4',
    ]);
    expect(streams.first.headers?['Referer'], 'https://video.vid3rb.com/');
  });

  test('resolveStreams switches source via Livewire and resolves Turnstile /sources API', () async {
    Uri? sourcesRequest;
    final resolver = Anime3rbPlaybackResolver(
      _StubTransport((uri, _, _) async {
        if (uri.path.startsWith('/episode/')) {
          return Anime3rbHttpResponse(statusCode: 200, body: _episodeHtml());
        }
        if (uri.path == '/player/uuid-2/sources') {
          sourcesRequest = uri;
          return Anime3rbHttpResponse(
            statusCode: 200,
            body: jsonEncode([
              {'src': 'https://files-3.vid3rb.com/720.mp4', 'label': '720p', 'premium': false},
            ]),
          );
        }
        if (uri.path == '/player/uuid-2') {
          return const Anime3rbHttpResponse(
            statusCode: 200,
            body: '<script>var video_sources = []; sitekey: "0x4AAAAA";</script>',
          );
        }
        return const Anime3rbHttpResponse(statusCode: 404, body: '');
      }, onPost: (uri, body) async {
        expect(uri.toString(), 'https://anime3rb.com/livewire-daa1cdb1/update');
        return Anime3rbHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'components': [
              {
                'snapshot': jsonEncode({
                  'data': {
                    'video_url': 'https://video.vid3rb.com/player/uuid-2?token=t2&expires=999',
                  },
                }),
              },
            ],
          }),
        );
      }),
      turnstileResolver: (playerUri) async => (token: 'cf-tok', type: 'invisible'),
    );

    final sources = await resolver.loadSources(
      'https://anime3rb.com/episode/one-piece/1180',
      forDownload: false,
    );
    // Pick the 2nd watch source (src2), triggering Livewire setVideoSource.
    final streams = await resolver.resolveStreams(
      sources[1].url,
      forDownload: false,
    );
    expect(sourcesRequest?.queryParameters['cf_token'], 'cf-tok');
    expect(sourcesRequest?.queryParameters['cf_token_type'], 'invisible');
    expect(streams.single.url, 'https://files-3.vid3rb.com/720.mp4');
  });

  test('resolveStreams follows 2-hop /download/{uuid} redirect and surfaces Cloudflare 403', () async {
    final resolver = Anime3rbPlaybackResolver(
      _StubTransport((uri, _, _) async {
        if (uri.path.startsWith('/episode/')) {
          return Anime3rbHttpResponse(statusCode: 200, body: _episodeHtml());
        }
        if (uri.path == '/download/free-1080' && uri.queryParameters['signature'] == 'sig2') {
          return const Anime3rbHttpResponse(
            statusCode: 200,
            body: '<a href="https://anime3rb.com/download/free-1080?expires=1000&amp;signature=sig3">تحميل مباشر</a>',
          );
        }
        if (uri.path == '/download/free-1080' && uri.queryParameters['signature'] == 'sig3') {
          return const Anime3rbHttpResponse(
            statusCode: 302,
            body: '',
            headers: {
              'location': ['https://files-3.vid3rb.com/ep1180-1080p.mp4'],
            },
          );
        }
        return const Anime3rbHttpResponse(statusCode: 404, body: '');
      }),
    );

    final dlSources = await resolver.loadSources(
      'https://anime3rb.com/episode/one-piece/1180',
      forDownload: true,
    );
    final resolved = await resolver.resolveStreams(
      dlSources.first.url,
      forDownload: true,
    );
    expect(resolved.single.url, 'https://files-3.vid3rb.com/ep1180-1080p.mp4');

    final blockedResolver = Anime3rbPlaybackResolver(
      _StubTransport((uri, _, _) async {
        return const Anime3rbHttpResponse(
          statusCode: 403,
          body: '<title>Just a moment...</title>',
          headers: {'cf-mitigated': ['challenge']},
        );
      }),
    );
    expect(
      () => blockedResolver.loadSources(
        'https://anime3rb.com/episode/one-piece/1180',
        forDownload: false,
      ),
      throwsA(isA<ProviderBrowserRequiredException>()),
    );
  });
}
