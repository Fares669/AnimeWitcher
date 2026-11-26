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
  String? playerUrl =
      'https://video.vid3rb.com/player/uuid-1?token=t1&expires=999',
  bool includeDownloads = true,
}) {
  final snapshot = const HtmlEscape().convert(
    jsonEncode({
      'data': {'video_url': playerUrl ?? '', 'video_source': 'src1'},
    }),
  );
  final downloadBlock = includeDownloads
      ? '''
  <div wire:key="download.src1">
    <h3><small>ترجمة Crunchyroll</small></h3>
    <div class="grow flex flex-wrap gap-4 justify-center">
      <div class="grow sm:max-w-[400px] flex rounded-lg">
        <div class="grow flex flex-col">
          <label>جودة عالية بحجم أقل [1080p HEVC]</label>
          <a href="https://anime3rb.com/download/hevc-id?expires=999&signature=sig1">تحميل مباشر [210.03 ميغابايت]</a>
        </div>
        <a href="https://anime3rb.com/hevc">اعرف المزيد</a>
      </div>
      <div class="flex flex-col grow sm:max-w-[300px]">
        <label>جودة عالية [1080p]</label>
        <a href="https://anime3rb.com/download/free-1080?expires=999&signature=sig2">تحميل مباشر [282.12 ميغابايت]</a>
      </div>
      <div class="flex flex-col grow sm:max-w-[300px]">
        <label>جودة متوسطة [720p]</label>
        <a href="https://anime3rb.com/download/free-720?expires=999&signature=sig3">تحميل مباشر [134.29 ميغابايت]</a>
      </div>
    </div>
  </div>
'''
      : '';
  return '''
<html>
<head><meta name="csrf-token" content="csrf123"></head>
<body>
  <script src="/livewire/livewire.min.js" data-csrf="csrf123" data-update-uri="https://anime3rb.com/livewire-daa1cdb1/update"></script>
  <div wire:name="video.show-video" wire:snapshot="$snapshot">
    <button data-video-source="src1"><span title="ترجمة Crunchyroll">ترجمة Crunchyroll</span></button>
    <button data-video-source="src2"><span title="ترجمة بديلة">ترجمة بديلة</span></button>
  </div>
  $downloadBlock
</body>
</html>
''';
}

void main() {
  test('loadSources extracts watch and download qualities directly from Vid3rb player with re-3arabi iframe headers and caches them', () async {
    var playerRequests = 0;
    final resolver = Anime3rbPlaybackResolver(
      _StubTransport((uri, headers, _) async {
        if (uri.path.startsWith('/episode/')) {
          return Anime3rbHttpResponse(statusCode: 200, body: _episodeHtml());
        }
        if (uri.path == '/player/uuid-1') {
          playerRequests++;
          expect(headers['Referer'], 'https://anime3rb.com/');
          expect(headers['Sec-Fetch-Dest'], 'iframe');
          expect(headers['Sec-Fetch-Site'], 'cross-site');
          return const Anime3rbHttpResponse(
            statusCode: 200,
            body: '''
<script>
var video_sources = [
  {"src": "https:\\/\\/cdn.vid3rb.com\\/prem.mp4", "label": "1080p Premium", "premium": true},
  {"src": "https:\\/\\/cdn.vid3rb.com\\/480.mp4?a=1\\u0026b=2", "label": "480p", "premium": false},
  {"src": "https:\\/\\/cdn.vid3rb.com\\/1080.mp4", "label": "1080p", "premium": false}
];
</script>
''',
          );
        }
        return const Anime3rbHttpResponse(statusCode: 404, body: '');
      }),
    );

    final playSources = await resolver.loadSources(
      'https://anime3rb.com/episode/one-piece/1180',
      forDownload: false,
    );
    expect(playSources, hasLength(3));
    expect(playSources[0].url, 'https://cdn.vid3rb.com/1080.mp4');
    expect(playSources[0].quality, '1080p');
    expect(playSources[0].source, 'Vid3rb · ترجمة Crunchyroll');
    expect(playSources[0].requiresResolution, isFalse);
    expect(playSources[0].headers?['Referer'], 'https://video.vid3rb.com/');

    expect(playSources[1].url, 'https://cdn.vid3rb.com/480.mp4?a=1&b=2');
    expect(playSources[1].quality, '480p');
    expect(playSources[1].requiresResolution, isFalse);

    // Secondary translation remains available as a deferred Vid3rb token.
    expect(playSources[2].source, 'Vid3rb · ترجمة بديلة');
    expect(playSources[2].requiresResolution, isTrue);

    // Download mode reuses the same player-extracted sources (cached).
    final dlSources = await resolver.loadSources(
      'https://anime3rb.com/episode/one-piece/1180',
      forDownload: true,
    );
    expect(playerRequests, 1);
    expect(dlSources.first.url, 'https://cdn.vid3rb.com/1080.mp4');
    expect(dlSources.first.quality, '1080p');

    // resolveStreams with an episode URL returns the direct player streams cleanly.
    final resolved = await resolver.resolveStreams(
      'https://anime3rb.com/episode/one-piece/1180',
      forDownload: false,
    );
    expect(resolved.map((s) => s.url).toList(), [
      'https://cdn.vid3rb.com/1080.mp4',
      'https://cdn.vid3rb.com/480.mp4?a=1&b=2',
    ]);
  });

  test('resolveStreams switches secondary translation via Livewire and resolves Turnstile /sources API', () async {
    Uri? sourcesRequest;
    final resolver = Anime3rbPlaybackResolver(
      _StubTransport((uri, _, _) async {
        if (uri.path.startsWith('/episode/')) {
          return Anime3rbHttpResponse(
            statusCode: 200,
            body: _episodeHtml(includeDownloads: false),
          );
        }
        if (uri.path == '/player/uuid-1') {
          return const Anime3rbHttpResponse(
            statusCode: 200,
            body: '''
<script>
var video_sources = [
  {"src": "https://files-3.vid3rb.com/1080.mp4", "label": "1080p", "premium": false}
];
</script>
''',
          );
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
      turnstileResolver: (playerUri) async =>
          const Anime3rbTurnstileResult(token: 'cf-tok', type: 'invisible'),
    );

    final sources = await resolver.loadSources(
      'https://anime3rb.com/episode/one-piece/1180',
      forDownload: false,
    );
    // Pick the deferred secondary translation (src2), triggering Livewire setVideoSource.
    final secondary = sources.firstWhere((s) => s.requiresResolution);
    final streams = await resolver.resolveStreams(
      secondary.url,
      forDownload: false,
    );
    expect(sourcesRequest?.queryParameters['cf_token'], 'cf-tok');
    expect(sourcesRequest?.queryParameters['cf_token_type'], 'invisible');
    expect(streams.single.url, 'https://files-3.vid3rb.com/720.mp4');
    expect(streams.single.quality, '720p');
  });

  test('falls back to 2-hop /download/{uuid} when no Vid3rb player exists and surfaces Cloudflare 403', () async {
    final resolver = Anime3rbPlaybackResolver(
      _StubTransport((uri, _, _) async {
        if (uri.path.startsWith('/episode/')) {
          return Anime3rbHttpResponse(
            statusCode: 200,
            body: _episodeHtml(playerUrl: null, includeDownloads: true),
          );
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

  test('loadSources parses pre-resolved sourcesJson captured inside Turnstile WebView even when Dio player GET returns 403', () async {
    var hitSourcesEndpoint = false;
    final resolver = Anime3rbPlaybackResolver(
      _StubTransport((uri, _, _) async {
        if (uri.path.startsWith('/episode/')) {
          return Anime3rbHttpResponse(
            statusCode: 200,
            body: _episodeHtml(includeDownloads: false),
          );
        }
        if (uri.path == '/player/uuid-1') {
          return const Anime3rbHttpResponse(
            statusCode: 403,
            body: '<title>Just a moment...</title>',
            headers: {'cf-mitigated': ['challenge']},
          );
        }
        if (uri.path == '/player/uuid-1/sources') {
          hitSourcesEndpoint = true;
        }
        return const Anime3rbHttpResponse(statusCode: 404, body: '');
      }),
      turnstileResolver: (_) async => Anime3rbTurnstileResult(
        sourcesJson: jsonEncode([
          {
            'src': 'https://files-4.vid3rb.com/1080p.mp4',
            'label': '1080p',
            'premium': false,
          },
          {
            'src': 'https://files-4.vid3rb.com/720p.mp4',
            'label': '720p',
            'premium': false,
          },
        ]),
      ),
    );

    final sources = await resolver.loadSources(
      'https://anime3rb.com/episode/one-piece/1180',
      forDownload: true,
    );
    expect(hitSourcesEndpoint, isFalse);
    expect(sources.first.url, 'https://files-4.vid3rb.com/1080p.mp4');
    expect(sources.first.quality, '1080p');
    expect(sources.first.requiresResolution, isFalse);
    expect(sources[1].url, 'https://files-4.vid3rb.com/720p.mp4');
    expect(sources[1].quality, '720p');
  });

  test('vid3rb regex stops before HTML-escaped &quot; and skips empty premium entries from live /sources payload', () async {
    Uri? requestedPlayer;
    final resolver = Anime3rbPlaybackResolver(
      _StubTransport((uri, _, _) async {
        if (uri.path.startsWith('/episode/')) {
          return const Anime3rbHttpResponse(
            statusCode: 200,
            body:
                '<div wire:snapshot="{&quot;data&quot;:{&quot;video_url&quot;:&quot;https:\\/\\/video.vid3rb.com\\/player\\/a2d9?token=tok1&amp;expires=999&quot;,&quot;video_source&quot;:&quot;s1&quot;}}"></div>',
          );
        }
        requestedPlayer = uri;
        return const Anime3rbHttpResponse(
          statusCode: 200,
          body: '<script>var video_sources = [];</script>',
        );
      }),
      turnstileResolver: (_) async => Anime3rbTurnstileResult(
        sourcesJson: jsonEncode([
          {'src': '', 'type': 'video/mp4', 'label': '1080p Premium', 'res': '10802', 'premium': true},
          {'src': 'https://video.vid3rb.com/video/id-1080?token=a', 'type': 'video/mp4', 'label': '1080p', 'res': '1080', 'premium': false},
          {'src': 'https://video.vid3rb.com/video/id-720?token=b', 'type': 'video/mp4', 'label': '720p', 'res': '720', 'premium': false},
          {'src': 'https://video.vid3rb.com/video/id-480?token=c', 'type': 'video/mp4', 'label': '480p', 'res': '480', 'premium': false},
        ]),
      ),
    );

    final streams = await resolver.loadSources(
      'https://anime3rb.com/episode/one-piece/1180',
      forDownload: false,
    );
    expect(requestedPlayer?.toString(), 'https://video.vid3rb.com/player/a2d9?token=tok1&expires=999');
    expect(streams.map((s) => s.quality).toList(), ['1080p', '720p', '480p']);
    expect(streams.map((s) => s.url).toList(), [
      'https://video.vid3rb.com/video/id-1080?token=a',
      'https://video.vid3rb.com/video/id-720?token=b',
      'https://video.vid3rb.com/video/id-480?token=c',
    ]);
  });

  test('DioAnime3rbTransport invokes challengeResolver on 403 challenge and retries with solved cookies', () async {
    var attempts = 0;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          attempts++;
          if (attempts == 1) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 403,
                headers: Headers.fromMap({
                  'cf-mitigated': ['challenge'],
                }),
                data: '<title>Just a moment...</title>',
              ),
            );
            return;
          }
          expect(options.headers['Cookie']?.toString(), contains('cf_clearance=cleared-123'));
          handler.resolve(
            Response<String>(
              requestOptions: options,
              statusCode: 200,
              data: '<div class="titles-list">ok</div>',
            ),
          );
        },
      ),
    );

    final transport = DioAnime3rbTransport(
      dio: dio,
      challengeResolver: (uri, {currentCookies = const <String, String>{}}) async => (
        cookies: const {'cf_clearance': 'cleared-123'},
        html: null,
        userAgent: null,
      ),
    );

    final html = await transport.fetchHtml(Uri.https('anime3rb.com', '/download/free-1080'));
    expect(attempts, 2);
    expect(html, contains('ok'));
  });

  test('isCloudflareChallenge recognizes modern Performing security verification interstitials', () {
    const resp = Anime3rbHttpResponse(
      statusCode: 403,
      body:
          '<html><body><h1>anime3rb.com</h1>'
          '<h2>Performing security verification</h2>'
          '<p>This website uses a security service to protect against malicious bots. '
          'This page is displayed while the website verifies you are not a bot.</p>'
          '</body></html>',
    );
    expect(resp.isCloudflareChallenge, isTrue);
  });

  test('DioAnime3rbTransport coalesces concurrent 403 challenges on the same domain into one solve', () async {
    var resolverCalls = 0;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final cookie = options.headers['Cookie']?.toString() ?? '';
          if (!cookie.contains('cf_clearance=ios-cleared')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 403,
                headers: Headers.fromMap({
                  'cf-mitigated': ['challenge'],
                }),
                data: '<title>Performing security verification</title>',
              ),
            );
            return;
          }
          expect(
            options.headers['User-Agent'],
            'Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
          );
          expect(options.headers.containsKey('sec-ch-ua'), isFalse);
          handler.resolve(
            Response<String>(
              requestOptions: options,
              statusCode: 200,
              data: '<div data-path="${options.uri.path}">ok</div>',
            ),
          );
        },
      ),
    );

    final transport = DioAnime3rbTransport(
      dio: dio,
      challengeResolver: (uri, {currentCookies = const <String, String>{}}) async {
        resolverCalls++;
        await Future<void>.delayed(const Duration(milliseconds: 25));
        return (
          cookies: const {'cf_clearance': 'ios-cleared'},
          html: '<div data-path="${uri.path}">webview</div>',
          userAgent:
              'Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
        );
      },
    );

    final results = await Future.wait([
      transport.fetchHtml(Uri.https('anime3rb.com', '/')),
      transport.fetchHtml(Uri.https('anime3rb.com', '/titles/list')),
      transport.fetchHtml(Uri.https('anime3rb.com', '/titles/list/movie')),
    ]);

    expect(resolverCalls, 1);
    expect(results[0], contains('data-path="/"'));
    expect(results[1], contains('data-path="/titles/list"'));
    expect(results[2], contains('data-path="/titles/list/movie"'));
  });

  test('DioAnime3rbTransport respects dismissal cooldown until reset and never reuses another URI HTML on TLS-bound 403', () async {
    var resolverCalls = 0;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response<String>(
              requestOptions: options,
              statusCode: 403,
              headers: Headers.fromMap({
                'cf-mitigated': ['challenge'],
              }),
              data: '<title>Just a moment...</title>',
            ),
          );
        },
      ),
    );

    var shouldSolve = false;
    final transport = DioAnime3rbTransport(
      dio: dio,
      challengeResolver: (uri, {currentCookies = const <String, String>{}}) async {
        resolverCalls++;
        if (!shouldSolve) return null;
        return (
          cookies: const {'cf_clearance': 'wk-bound'},
          html: '<div data-webview-path="${uri.path}">ok</div>',
          userAgent:
              'Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
        );
      },
    );

    // Dismissed prompt enters cooldown so immediate follow-up doesn't re-open it.
    await expectLater(
      transport.fetchHtml(Uri.https('anime3rb.com', '/')),
      throwsA(isA<Anime3rbBrowserRequiredException>()),
    );
    await expectLater(
      transport.fetchHtml(Uri.https('anime3rb.com', '/titles/list')),
      throwsA(isA<Anime3rbBrowserRequiredException>()),
    );
    expect(resolverCalls, 1);

    // Explicit retry resets cooldown; when Dio stays 403, each URI gets its own HTML.
    shouldSolve = true;
    transport.resetChallengeCooldown();
    final pages = await Future.wait([
      transport.fetchHtml(Uri.https('anime3rb.com', '/')),
      transport.fetchHtml(Uri.https('anime3rb.com', '/titles/list')),
    ]);
    expect(pages[0], contains('data-webview-path="/"'));
    expect(pages[1], contains('data-webview-path="/titles/list"'));
  });

  test('normalizeAnime3rbWebViewUserAgent preserves iOS WKWebView UA untouched and strips wv on Android', () {
    expect(
      normalizeAnime3rbWebViewUserAgent(
        'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
      ),
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
    );
    expect(
      normalizeAnime3rbWebViewUserAgent(
        'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/UP1A.231005.007; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/134.0.6998.135 Mobile Safari/537.36',
      ),
      'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/UP1A.231005.007) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.6998.135 Mobile Safari/537.36',
    );
  });

  test('DioAnime3rbTransport switches to parked webViewFetcher when Dio stays TLS-blocked after challenge solve', () async {
    var dioCalls = 0;
    var solverCalls = 0;
    var webViewFetchCalls = 0;

    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          dioCalls++;
          handler.resolve(
            Response<String>(
              requestOptions: options,
              statusCode: 403,
              headers: Headers.fromMap({
                'cf-mitigated': ['challenge'],
              }),
              data: '<title>Performing security verification</title>',
            ),
          );
        },
      ),
    );

    final transport = DioAnime3rbTransport(
      dio: dio,
      challengeResolver: (uri, {currentCookies = const <String, String>{}}) async {
        solverCalls++;
        return (
          cookies: const {'cf_clearance': 'wk-bound'},
          html: '<div data-path="${uri.path}">solved-home</div>',
          userAgent:
              'Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1',
        );
      },
      webViewFetcher: (
        uri, {
        method = 'GET',
        headers = const {},
        body,
        followRedirects = true,
      }) async {
        webViewFetchCalls++;
        return Anime3rbHttpResponse(
          statusCode: 200,
          body: '<div data-wv-path="${uri.path}" data-method="$method">ok</div>',
          finalUri: uri,
        );
      },
    );

    final firstWave = await Future.wait([
      transport.fetchHtml(Uri.https('anime3rb.com', '/')),
      transport.fetchHtml(Uri.https('anime3rb.com', '/titles/list')),
      transport.fetchHtml(Uri.https('anime3rb.com', '/titles/list/movie')),
    ]);

    expect(solverCalls, 1);
    expect(firstWave[0], contains('solved-home'));
    expect(firstWave[1], contains('data-wv-path="/titles/list"'));
    expect(firstWave[2], contains('data-wv-path="/titles/list/movie"'));

    final dioCallsAfterFirstWave = dioCalls;
    // Subsequent GET and POST go directly through the parked WebView fetch bridge
    // without wasting Dio 403 round-trips or opening another challenge modal.
    final details = await transport.fetchHtml(
      Uri.https('anime3rb.com', '/titles/one-piece'),
    );
    final postResp = await transport.post(
      Uri.https('anime3rb.com', '/livewire/update'),
      body: '{"query":"one piece"}',
      headers: const {'Content-Type': 'application/json'},
    );

    expect(dioCalls, dioCallsAfterFirstWave);
    expect(solverCalls, 1);
    expect(webViewFetchCalls, 4);
    expect(details, contains('data-wv-path="/titles/one-piece"'));
    expect(postResp.statusCode, 200);
    expect(postResp.body, contains('data-method="POST"'));
  });
}
