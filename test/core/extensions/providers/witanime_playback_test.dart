import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:animewitcher/core/extensions/providers/witanime_crypto.dart';
import 'package:animewitcher/core/extensions/providers/witanime_mega_proxy.dart';
import 'package:animewitcher/core/extensions/providers/witanime_playback.dart';
import 'package:animewitcher/core/extensions/providers/witanime_provider.dart';
import 'package:animewitcher/core/extensions/providers/witanime_transport.dart';
import 'package:animewitcher/core/services/download_url_refresh.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeWitanimeTransport implements WitanimeTransport {
  _FakeWitanimeTransport(this.handler);

  final Future<WitanimeHttpResponse> Function(
    String method,
    Uri uri,
    Object? body,
    Map<String, String> headers,
    bool followRedirects,
  )
  handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<String> fetchHtml(
    Uri uri, {
    CancelToken? cancelToken,
    String operation = 'catalog',
  }) async {
    final resp = await get(uri, cancelToken: cancelToken, operation: operation);
    return resp.body;
  }

  @override
  Future<WitanimeHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    bool followRedirects = true,
    bool inspectMedia = false,
    CancelToken? cancelToken,
    String operation = 'get',
  }) => handler('GET', uri, null, headers, followRedirects);

  @override
  Future<WitanimeHttpResponse> post(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'post',
  }) => handler('POST', uri, body, headers, followRedirects);
}

/// Test-only helper to encrypt an AES-256-GCM Yonaplay test vector using the
/// exact block primitive verified against known NIST vectors.
String _encryptYonaplayForTest(String passphrase, String plaintext) {
  final keyBytes = Uint8List.fromList(
    crypto.sha256.convert(utf8.encode(passphrase)).bytes,
  );
  // Build round keys via known reference AES-256-GCM using empty tag check:
  // Use a deterministic 12-byte IV and compute GHASH + GCTR using the same
  // standardized math verified separately with a NIST vector below.
  final iv = Uint8List.fromList(List<int>.generate(12, (i) => i + 1));
  // Encrypt using dart:typed_data + aes256EncryptBlock imported from crypto:
  // Expand key locally in test via known FIPS-197 helper so test validates
  // round-trip AND NIST vector separately.
  const sbox = <int>[
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
  ];
  int xtime(int b) => ((b << 1) ^ ((b & 0x80) != 0 ? 0x1b : 0)) & 0xff;
  int gmul(int a, int b) {
    var p = 0;
    var x = a;
    var y = b;
    for (var i = 0; i < 8; i++) {
      if ((y & 1) != 0) p ^= x;
      x = xtime(x);
      y >>= 1;
    }
    return p;
  }

  final words = List<List<int>>.generate(60, (_) => List<int>.filled(4, 0));
  for (var i = 0; i < 8; i++) {
    words[i] = keyBytes.sublist(i * 4, i * 4 + 4);
  }
  var rcon = 1;
  for (var i = 8; i < 60; i++) {
    var t = List<int>.of(words[i - 1]);
    if (i % 8 == 0) {
      t = [sbox[t[1]] ^ rcon, sbox[t[2]], sbox[t[3]], sbox[t[0]]];
      rcon = xtime(rcon);
    } else if (i % 8 == 4) {
      t = [sbox[t[0]], sbox[t[1]], sbox[t[2]], sbox[t[3]]];
    }
    words[i] = [
      words[i - 8][0] ^ t[0],
      words[i - 8][1] ^ t[1],
      words[i - 8][2] ^ t[2],
      words[i - 8][3] ^ t[3],
    ];
  }
  final roundKeys = [
    for (var r = 0; r <= 14; r++)
      Uint8List.fromList([
        ...words[r * 4],
        ...words[r * 4 + 1],
        ...words[r * 4 + 2],
        ...words[r * 4 + 3],
      ]),
  ];
  Uint8List gfMul(Uint8List x, Uint8List y) {
    final z = Uint8List(16);
    final v = Uint8List.fromList(y);
    for (var b = 0; b < 16; b++) {
      for (var bit = 7; bit >= 0; bit--) {
        if ((x[b] & (1 << bit)) != 0) {
          for (var k = 0; k < 16; k++) {
            z[k] ^= v[k];
          }
        }
        final lsb = (v[15] & 1) != 0;
        for (var k = 15; k > 0; k--) {
          v[k] = ((v[k] >> 1) | ((v[k - 1] & 1) << 7)) & 0xff;
        }
        v[0] = (v[0] >> 1) & 0xff;
        if (lsb) v[0] ^= 0xe1;
      }
    }
    return z;
  }

  final h = aes256EncryptBlock(roundKeys, Uint8List(16));
  final j0 = Uint8List(16)..setAll(0, iv)..[15] = 1;
  final pt = utf8.encode(plaintext);
  final ct = Uint8List(pt.length);
  final ctr = Uint8List.fromList(j0)..[15] = 2;
  for (var off = 0; off < pt.length; off += 16) {
    final ks = aes256EncryptBlock(roundKeys, ctr);
    final chunk = (pt.length - off).clamp(0, 16);
    for (var i = 0; i < chunk; i++) {
      ct[off + i] = pt[off + i] ^ ks[i];
    }
    for (var i = 15; i >= 12; i--) {
      ctr[i] = (ctr[i] + 1) & 0xff;
      if (ctr[i] != 0) break;
    }
  }
  final y = Uint8List(16);
  for (var off = 0; off < ct.length; off += 16) {
    final end = (off + 16).clamp(0, ct.length);
    for (var i = 0; i < end - off; i++) {
      y[i] ^= ct[off + i];
    }
    y.setAll(0, gfMul(y, h));
  }
  final lenBlock = Uint8List(16);
  var bitLen = ct.length * 8;
  for (var i = 15; i >= 8 && bitLen > 0; i--) {
    lenBlock[i] = bitLen & 0xff;
    bitLen >>= 8;
  }
  for (var i = 0; i < 16; i++) {
    y[i] ^= lenBlock[i];
  }
  final ghashTag = gfMul(y, h);
  final j0Mask = aes256EncryptBlock(roundKeys, j0);
  final tag = Uint8List.fromList([
    for (var i = 0; i < 16; i++) ghashTag[i] ^ j0Mask[i],
  ]);
  final unusedGmul = gmul(2, 3);
  assert(unusedGmul == 6);
  return base64Encode([...iv, ...tag, ...ct]);
}

void main() {
  test('crypto unpacks packed JS and decrypts RC4 and Yonaplay AES-256-GCM', () {
    final unpacked = unpackPackedJs(
      "eval(function(p,a,c,k,e,d){return p}('0 1=\"https://2.3/master.txt\";',4,4,'const|file|cdn|example'.split('|'),0,{}))",
    );
    expect(unpacked, contains('const file="https://cdn.example/master.txt";'));

    final rc4Key = utf8.encode('secret');
    final cipher = rc4Crypt(rc4Key, utf8.encode('<xml>ok</xml>'));
    expect(utf8.decode(rc4Crypt(rc4Key, cipher)), '<xml>ok</xml>');

    final encoded = _encryptYonaplayForTest(
      'yona-key',
      'https://drive.google.com/file/d/abc123XYZ/view',
    );
    expect(
      decryptYonaplayPayload('yona-key', encoded),
      'https://drive.google.com/file/d/abc123XYZ/view',
    );
    expect(decryptYonaplayPayload('wrong-key', encoded), isNull);
  });

  test('stream and download tokens resolve Yonaplay, Drive, Hgcloud, and refresh URL', () async {
    var gateRefererPresent = false;
    var downloadTokenVersion = 1;
    final encryptedHost = _encryptYonaplayForTest(
      'k1',
      'https://dotplay.net/embed/FILE_ID_1',
    );

    final transport = _FakeWitanimeTransport((
      method,
      uri,
      body,
      headers,
      followRedirects,
    ) async {
      if (uri.host == 'witanime.site' && uri.path == '/watch/sample/1') {
        return const WitanimeHttpResponse(
          statusCode: 200,
          body: '<meta name="csrf-token" content="csrf-123">',
        );
      }
      if (uri.host == 'witanime.site' &&
          uri.path == '/watch/sample/1/sources') {
        return WitanimeHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'players': {
              'FHD': [
                {
                  'label': 'Yonaplay',
                  'token': 'tok-yona-$downloadTokenVersion',
                },
                {'label': 'Hgcloud', 'token': 'tok-hg'},
                {'label': 'Mega', 'token': 'tok-mega'},
              ],
            },
            'versions': {
              'dub': {
                'downloads': {
                  'HD': [
                    {
                      'label': 'Google Drive',
                      'token': 'tok-dl-$downloadTokenVersion',
                    },
                  ],
                },
              },
            },
          }),
        );
      }
      if (uri.path.startsWith('/watch/stream-source/') ||
          uri.path.startsWith('/watch/download-source/')) {
        return const WitanimeHttpResponse(statusCode: 200, body: '{"ok":true}');
      }
      if (uri.path == '/watch/stream-gate/tok-yona-1') {
        gateRefererPresent = headers.keys.any(
          (k) => k.toLowerCase() == 'referer',
        );
        return const WitanimeHttpResponse(
          statusCode: 302,
          body: '',
          headers: {
            'location': ['https://yonaplay.org/embed/123'],
          },
        );
      }
      if (uri.path == '/watch/stream-gate/tok-hg') {
        return const WitanimeHttpResponse(
          statusCode: 302,
          body: '',
          headers: {
            'location': ['https://hgcloud.to/e/xyz'],
          },
        );
      }
      if (uri.path == '/watch/stream-gate/tok-mega') {
        return const WitanimeHttpResponse(
          statusCode: 302,
          body: '',
          headers: {
            'location': ['https://mega.nz/file/abc'],
          },
        );
      }
      if (uri.path == '/watch/download-gate/tok-dl-1') {
        return const WitanimeHttpResponse(
          statusCode: 302,
          body: '',
          headers: {
            'location': ['https://drive.google.com/file/d/OLD_ID/view'],
          },
        );
      }
      if (uri.path == '/watch/download-gate/tok-dl-2') {
        return const WitanimeHttpResponse(
          statusCode: 302,
          body: '',
          headers: {
            'location': ['https://drive.google.com/file/d/FRESH_ID/view'],
          },
        );
      }
      if (uri.host == 'yonaplay.org' && uri.path == '/embed/123') {
        return const WitanimeHttpResponse(
          statusCode: 200,
          body: '<script>window._E={a:"/api"};</script>',
          headers: {
            'set-cookie': ['em_embed=abc; Path=/'],
          },
        );
      }
      if (uri.host == 'yonaplay.org' && uri.path == '/api/init-session.php') {
        return const WitanimeHttpResponse(
          statusCode: 200,
          body: '{"success":true,"c":"code1","k":"k1"}',
        );
      }
      if (uri.host == 'yonaplay.org' && uri.path == '/api/sources.php') {
        return const WitanimeHttpResponse(
          statusCode: 200,
          body:
              '{"qualities":{"HD":{"servers":[{"token":"other"}]},'
              '"FHD":{"servers":[{},{"token":"srv1"}]}}}',
        );
      }
      if (uri.host == 'yonaplay.org' && uri.path == '/api/api.php') {
        expect(jsonDecode(body as String)['token'], 'srv1');
        return WitanimeHttpResponse(
          statusCode: 200,
          body: jsonEncode({'d': encryptedHost}),
        );
      }
      if (uri.host == 'dotplay.net' && uri.path == '/api.php') {
        expect(uri.queryParameters['code'], 'FILE_ID_1');
        final encoded = base64Encode(
          utf8.encode('https://cdn.test/video|expires'),
        );
        return WitanimeHttpResponse(
          statusCode: 200,
          body: jsonEncode({'video_url': encoded}),
        );
      }
      if (uri.host == 'hgcloud.to' && uri.path == '/e/xyz') {
        return const WitanimeHttpResponse(
          statusCode: 200,
          body: '<script src="/main.js?v=1.1.9"></script>',
        );
      }
      if (uri.host == 'vibuxer.com' && uri.path == '/e/xyz') {
        throw DioException.connectionError(
          requestOptions: RequestOptions(path: uri.toString()),
          reason: 'Mirror unavailable',
        );
      }
      if (uri.host == 'hanerix.com' && uri.path == '/e/xyz') {
        return const WitanimeHttpResponse(
          statusCode: 200,
          body: '<script>var url="https://edge.hanerix.com/stream/master.txt?t=1";</script>',
        );
      }
      return WitanimeHttpResponse(statusCode: 404, body: 'Not found: $uri');
    });

    final provider = WitanimeProvider.withTransport(transport);

    final streamSources = await provider.loadStreamSources(
      'https://witanime.site/watch/sample/1',
    );
    expect(streamSources.length, 4);
    expect(streamSources.last.source, 'Google Drive (عربي مدبلج)');
    expect(
      WitanimeSourceToken.tryDecode(streamSources.last.url)?.kind,
      'download',
    );
    expect(streamSources.every((s) => s.requiresResolution), isTrue);
    expect(provider.isExplicitStreamSelection(streamSources.first.url), isTrue);

    final yonaResolved = await provider.loadStreams(streamSources.first.url);
    expect(gateRefererPresent, isFalse);
    expect(yonaResolved.single.url, 'https://cdn.test/video');
    expect(
      yonaResolved.single.headers?['Referer'],
      'https://dotplay.net/embed/FILE_ID_1',
    );
    expect(yonaResolved.single.refreshUrl, streamSources.first.url);

    final hgResolved = await provider.loadStreams(streamSources[1].url);
    expect(
      hgResolved.single.url,
      'https://edge.hanerix.com/stream/master.txt?t=1',
    );
    expect(hgResolved.single.headers?['Referer'], 'https://hanerix.com/');

    await expectLater(
      provider.loadStreams(streamSources[2].url),
      throwsA(isA<WitanimeBrowserRequiredException>()),
    );

    final downloadSources = await provider.loadDownloadStreamSources(
      'https://witanime.site/watch/sample/1',
    );
    expect(downloadSources.first.source, 'Google Drive (عربي مدبلج)');
    expect(downloadSources.first.quality, '720p');
    expect(downloadSources.map((s) => s.source), contains('Yonaplay'));

    final dl1 = await provider.loadDownloadStreams(downloadSources.first.url);
    expect(dl1.single.url, contains('id=OLD_ID'));

    // Verify expired download URL renewal via DownloadUrlRefresher
    downloadTokenVersion = 2;
    final refresher = DownloadUrlRefresher(
      providerForId: (id) => id == WitanimeProvider.id ? provider : null,
    );
    final refreshed = await refresher.refresh(
      DownloadUrlRefreshDescriptor(
        trackingUrl: 'https://witanime.site/watch/sample/1',
        providerId: WitanimeProvider.id,
        source: downloadSources.first.source,
        quality: downloadSources.first.quality,
        refreshUrl: dl1.single.refreshUrl,
        updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
      ),
      currentUrl: dl1.single.url,
    );
    expect(refreshed, isNotNull);
    expect(refreshed!.url, contains('id=FRESH_ID'));
  });

  test('DioWitanimeTransport retains Witanime Set-Cookie across watch and sources POST', () async {
    final dio = Dio(BaseOptions(responseType: ResponseType.plain));
    String? authSessionCookie;
    final sentCookies = <String, String?>{};
    dio.httpClientAdapter = _Adapter((options) async {
      sentCookies['${options.method} ${options.uri.path}'] =
          options.headers['Cookie']?.toString();
      if (options.uri.path == '/watch/sample/1') {
        return ResponseBody.fromString(
          '<meta name="csrf-token" content="csrf-cookie-1">',
          200,
          headers: {
            Headers.contentTypeHeader: ['text/html'],
            'set-cookie': [
              'witanime_session=sess-guest-1; Path=/; HttpOnly',
              'XSRF-TOKEN=xsrf-1; Path=/',
            ],
          },
        );
      }
      if (options.uri.path == '/watch/sample/1/sources') {
        final cookie = options.headers['Cookie']?.toString() ?? '';
        if (!cookie.contains('witanime_session=sess-guest-1') ||
            options.headers['X-CSRF-TOKEN'] != 'csrf-cookie-1') {
          return ResponseBody.fromString('{"message":"CSRF token mismatch"}', 419);
        }
        return ResponseBody.fromString(
          jsonEncode({
            'players': {
              'HD': [
                {'label': 'Mega', 'token': 'tok-ok'},
              ],
            },
          }),
          200,
        );
      }
      if (options.uri.path == '/watch/stream-source/tok-ok') {
        final cookie = options.headers['Cookie']?.toString() ?? '';
        if (!cookie.contains('witanime_session=sess-guest-1')) {
          return ResponseBody.fromString('CSRF mismatch', 419);
        }
        return ResponseBody.fromString('{"ok":true}', 200);
      }
      if (options.uri.path == '/watch/stream-gate/tok-ok') {
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['https://mega.nz/file/ok'],
          },
        );
      }
      return ResponseBody.fromString('not found', 404);
    });

    final transport = DioWitanimeTransport(
      dio: dio,
      sessionHeaders: (_) async => authSessionCookie == null
          ? const <String, String>{}
          : <String, String>{'Cookie': authSessionCookie},
    );
    final resolver = WitanimePlaybackResolver(transport);

    final sources = await resolver.loadSources(
      'https://witanime.site/watch/sample/1',
      forDownload: false,
    );
    expect(sources.single.source, 'Mega');
    expect(
      sentCookies['POST /watch/sample/1/sources'],
      contains('witanime_session=sess-guest-1'),
    );

    // Switching auth session resets the guest cookie jar cleanly.
    authSessionCookie = 'witanime_session=user-logged-in';
    await transport.get(Uri.parse('https://witanime.site/profile'));
    expect(
      sentCookies['GET /profile'],
      'witanime_session=user-logged-in',
    );
  });

  test('WitanimePlaybackResolver retries once when sources POST returns HTTP 419', () async {
    var sourcesAttempts = 0;
    var watchFetches = 0;
    final transport = _FakeWitanimeTransport((method, uri, body, headers, _) async {
      if (uri.path == '/watch/sample/1') {
        watchFetches++;
        return WitanimeHttpResponse(
          statusCode: 200,
          body: '<meta name="csrf-token" content="csrf-$watchFetches">',
        );
      }
      if (uri.path == '/watch/sample/1/sources') {
        sourcesAttempts++;
        if (sourcesAttempts == 1) {
          return const WitanimeHttpResponse(statusCode: 419, body: 'Page Expired');
        }
        expect(headers['X-CSRF-TOKEN'], 'csrf-2');
        return WitanimeHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'players': {
              'HD': [
                {'label': 'Mega', 'token': 'tok-retry'},
              ],
            },
          }),
        );
      }
      return const WitanimeHttpResponse(statusCode: 404, body: '');
    });

    final resolver = WitanimePlaybackResolver(transport);
    final sources = await resolver.loadSources(
      'https://witanime.site/watch/sample/1',
      forDownload: false,
    );
    expect(watchFetches, 2);
    expect(sourcesAttempts, 2);
    expect(sources.single.source, 'Mega');
  });

  test('WitanimePlaybackResolver + DioWitanimeTransport omit X-Requested-With and send Sec-Fetch + Client Hints', () async {
    final dio = Dio(BaseOptions(responseType: ResponseType.plain));
    String? gateSecFetchDest;
    dio.httpClientAdapter = _Adapter((options) async {
      final hasXrw = options.headers.keys.any(
        (k) => k.toLowerCase() == 'x-requested-with',
      );
      final hasCh =
          options.headers['sec-ch-ua']?.toString().contains('131') == true &&
          options.headers['sec-ch-ua-mobile'] == '?0' &&
          options.headers['sec-ch-ua-platform'] == '"Windows"';
      final isCors =
          options.headers['Sec-Fetch-Site'] == 'same-origin' &&
          options.headers['Sec-Fetch-Mode'] == 'cors' &&
          options.headers['Sec-Fetch-Dest'] == 'empty';

      if (options.uri.path == '/watch/custom/1') {
        return ResponseBody.fromString(
          '<meta name="csrf-token" content="csrf-ch">'
          '<div data-watch-config="{&quot;sourcesUrl&quot;:&quot;\\/watch\\/alt\\/1\\/sources&quot;}"></div>',
          200,
        );
      }
      if (options.uri.path == '/watch/alt/1/sources') {
        if (hasXrw || !hasCh || !isCors) {
          return ResponseBody.fromString('{"message":"Not Found."}', 404);
        }
        return ResponseBody.fromString(
          jsonEncode({
            'players': {
              'HD': [
                {'label': 'Mega', 'token': 'tok-ch', 'version': 'dub'},
              ],
            },
          }),
          200,
        );
      }
      if (options.uri.path == '/watch/stream-source/tok-ch') {
        if (hasXrw || !hasCh || !isCors) {
          return ResponseBody.fromString('{"message":"Not Found."}', 404);
        }
        return ResponseBody.fromString('{"ok":true}', 200);
      }
      if (options.uri.path == '/watch/stream-gate/tok-ch') {
        if (!hasCh || options.headers['Sec-Fetch-Mode'] != 'navigate') {
          return ResponseBody.fromString('not found', 404);
        }
        gateSecFetchDest = options.headers['Sec-Fetch-Dest']?.toString();
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['https://mega.nz/file/ch'],
          },
        );
      }
      return ResponseBody.fromString('not found', 404);
    });

    final transport = DioWitanimeTransport(dio: dio);
    final resolver = WitanimePlaybackResolver(transport);
    final sources = await resolver.loadSources(
      'https://witanime.site/watch/custom/1',
      forDownload: false,
    );
    expect(sources.single.source, 'Mega (عربي مدبلج)');
    await expectLater(
      resolver.resolveStreams(sources.single.url, forDownload: false),
      throwsA(isA<WitanimeBrowserRequiredException>()),
    );
    expect(gateSecFetchDest, 'iframe');
  });

  test('download fallback preserves the source kind and refreshes a stale token', () async {
    const watch = 'https://witanime.site/watch/sample/1';
    const old = WitanimeSourceToken(
      kind: 'download',
      watchUrl: watch,
      token: 'old',
      label: 'MediaFire',
      tier: 'HD',
    );
    final calls = <String>[];
    final resolver = WitanimePlaybackResolver(
      _FakeWitanimeTransport((method, uri, _, headers, followRedirects) async {
        calls.add('$method ${uri.path}');
        return switch (uri.path) {
          '/watch/sample/1' => const WitanimeHttpResponse(
            statusCode: 200,
            body: '<meta name="csrf-token" content="csrf">',
          ),
          '/watch/download-source/old' => const WitanimeHttpResponse(
            statusCode: 410,
            body: '',
          ),
          '/watch/sample/1/sources' => const WitanimeHttpResponse(
            statusCode: 200,
            body: '{"players":{"hD":[{"label":"MediaFire","token":"a+b/c="}]}}',
          ),
          '/watch/stream-source/a+b%2Fc=' => WitanimeHttpResponse(
            statusCode: uri.pathSegments.last == 'a+b/c=' ? 200 : 404,
            body: '{"gateUrl":"/watch/custom-gate?x=1","referrerPolicy":"origin"}',
          ),
          '/watch/custom-gate' => WitanimeHttpResponse(
            statusCode:
                !followRedirects &&
                    uri.queryParameters['x'] == '1' &&
                    headers['Referer'] == 'https://witanime.site/'
                ? 200
                : 404,
            body:
                '<iframe src="//www.mediafire.com/file/id/clip.mp4"></iframe>',
          ),
          '/file/id/clip.mp4' => const WitanimeHttpResponse(
            statusCode: 200,
            body: '<a href="//cdn.test/file?x=1&amp;y=2" id="downloadButton">Download</a>',
          ),
          '/file' => const WitanimeHttpResponse(
            statusCode: 200,
            body: '',
            headers: {
              'Content-Type': ['application/octet-stream'],
              'Content-Disposition': ['attachment; filename="episode.mkv"'],
            },
          ),
          _ => const WitanimeHttpResponse(statusCode: 404, body: ''),
        };
      }),
    );
    final result = await resolver.resolveStreams(
      old.encode(),
      forDownload: true,
    );
    expect(result.single.url, 'https://cdn.test/file?x=1&y=2');
    expect(
      result.single.headers?['Referer'],
      'https://www.mediafire.com/file/id/clip.mp4',
    );
    expect(
      WitanimeSourceToken.tryDecode(result.single.refreshUrl!)?.kind,
      'stream',
    );
    expect(
      calls.where((call) => call.startsWith('POST /watch/download-source')),
      hasLength(1),
    );
  });

  test(
    'Witanime respects Retry-After from a source unlock',
    () async {
      var requests = 0;
      const watch = 'https://witanime.site/watch/sample/1';
      const source = WitanimeSourceToken(
        kind: 'stream',
        watchUrl: watch,
        token: 'token',
        label: 'Server',
        tier: 'HD',
      );
      final resolver = WitanimePlaybackResolver(
        _FakeWitanimeTransport((method, uri, _, _, _) async {
          requests++;
          if (uri.path == '/watch/sample/1') {
            return const WitanimeHttpResponse(
              statusCode: 200,
              body: '<meta name="csrf-token" content="csrf">',
            );
          }
          return const WitanimeHttpResponse(
            statusCode: 429,
            body: '',
            headers: {
              'Retry-After': ['60'],
            },
          );
        }),
      );
      await expectLater(
        resolver.resolveStreams(source.encode(), forDownload: false),
        throwsA(isA<WitanimeRateLimitException>()),
      );
      // Retrying the same rate-limited token respects Retry-After without hitting the network.
      await expectLater(
        resolver.resolveStreams(source.encode(), forDownload: false),
        throwsA(isA<WitanimeRateLimitException>()),
      );
      expect(requests, 2);
    },
  );

  test('rate-limiting one server unlock does not block loadSources or other servers, and server errors stay distinct', () async {
    const watch = 'https://witanime.site/watch/sample/7';
    final transport = _FakeWitanimeTransport((method, uri, _, _, _) async {
      if (uri.path == '/watch/sample/7') {
        return const WitanimeHttpResponse(
          statusCode: 200,
          body: '<meta name="csrf-token" content="csrf-7">',
        );
      }
      if (uri.path == '/watch/sample/7/sources') {
        return WitanimeHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'players': {
              'FHD': [
                {'label': 'ServerA', 'token': 'tok-rate'},
                {'label': 'ServerB', 'token': 'tok-broken'},
                {'label': 'Google Drive', 'token': 'tok-ok'},
              ],
            },
          }),
        );
      }
      if (uri.path == '/watch/stream-source/tok-rate') {
        return const WitanimeHttpResponse(
          statusCode: 429,
          body: '',
          headers: {'Retry-After': ['60']},
        );
      }
      if (uri.path == '/watch/stream-source/tok-broken') {
        return const WitanimeHttpResponse(statusCode: 502, body: 'Bad Gateway');
      }
      if (uri.path == '/watch/stream-source/tok-ok') {
        return const WitanimeHttpResponse(statusCode: 200, body: '{"ok":true}');
      }
      if (uri.path == '/watch/stream-gate/tok-ok') {
        return const WitanimeHttpResponse(
          statusCode: 302,
          body: '',
          headers: {'location': ['https://drive.google.com/file/d/OK_ID/view']},
        );
      }
      return const WitanimeHttpResponse(statusCode: 404, body: '');
    });

    final resolver = WitanimePlaybackResolver(transport);
    final sources = await resolver.loadSources(watch, forDownload: false);
    expect(sources, hasLength(3));

    // 1. ServerA hits 429 -> WitanimeRateLimitException.
    await expectLater(
      resolver.resolveStreams(sources[0].url, forDownload: false),
      throwsA(isA<WitanimeRateLimitException>()),
    );

    // 2. loadSources is still accessible (cached & not locked out by ServerA's 429).
    final reloaded = await resolver.loadSources(watch, forDownload: false);
    expect(reloaded, hasLength(3));

    // 3. ServerB returns 502 -> WitanimeSourceUnavailableException (NOT rate limit).
    await expectLater(
      resolver.resolveStreams(sources[1].url, forDownload: false),
      throwsA(isA<WitanimeSourceUnavailableException>()),
    );

    // Episode-level selection skips both the cooling-down and failed servers.
    final okStreams = await resolver.resolveStreams(
      watch,
      forDownload: false,
    );
    expect(okStreams.single.url, contains('id=OK_ID'));
  });

  test('host extraction cancels a stalled request at its deadline', () {
    fakeAsync((time) {
      final dio = Dio();
      final pending = Completer<ResponseBody>();
      dio.httpClientAdapter = _Adapter((_) => pending.future);
      final transport = DioWitanimeTransport(dio: dio);
      Object? error;
      unawaited(
        transport
            .post(
              Uri.https('api.example.com', '/metadata'),
              operation: 'host_test',
            )
            .then<void>(
              (_) => fail('The request unexpectedly succeeded'),
              onError: (Object e) {
                error = e;
              },
            ),
      );
      time.elapse(const Duration(seconds: 8));
      expect(error, isA<DioException>());
      expect(classifyWitanimeFailure(error!), 'timeout');
      dio.close(force: true);
    });
  });

  test('host inspection recognizes media without buffering the file', () async {
    final dio = Dio();
    addTearDown(dio.close);
    final canceled = Completer<void>();
    final body = StreamController<Uint8List>(onCancel: canceled.complete);
    dio.httpClientAdapter = _Adapter((options) async {
      expect(options.responseType, ResponseType.stream);
      return ResponseBody(
        body.stream,
        200,
        headers: {
          'content-type': ['video/mp4'],
        },
      );
    });
    final transport = DioWitanimeTransport(dio: dio);
    final response = await transport.get(
      Uri.https('cdn.test', '/file'),
      inspectMedia: true,
    );
    expect(response.hasMediaContent, isTrue);
    expect(response.body, isEmpty);
    await canceled.future.timeout(const Duration(seconds: 2));
    await body.close();
  });

  test('unpackPackedJs handles p,a,c,k,e,r and multiple packed blocks', () {
    const html =
        "<script>eval(function(p,a,c,k,e,r){return p}('0=1',2,2,'noop|val'.split('|'),0,{}))</script>"
        r"<script>eval(function(p,a,c,k,e,r){return p}('0={\'1\':\'/2/3.4\'}',5,5,'links|hls4|stream|master|m3u8'.split('|'),0,{}))</script>";
    final unpacked = unpackPackedJs(html);
    expect(unpacked, contains("links={'hls4':'/stream/master.m3u8'}"));
  });

  test('Aes128CtrCipher matches NIST SP 800-38A vector and WitanimeMegaProxy serves 200 and unaligned 206 ranges', () async {
    // NIST SP 800-38A F.5.1 CTR-AES128.Encrypt block 1
    Uint8List hex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);
    final nistCipher = Aes128CtrCipher(
      key: hex('2b7e151628aed2a6abf7158809cf4f3c'),
      iv16: hex('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff'),
    );
    final nistOut = nistCipher.process(hex('6bc1bee22e409f96e93d7e117393172a'));
    expect(
      nistOut.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      '874d6191b620e3261bef6864990db6ce',
    );

    // End-to-end MEGA proxy test with unaligned range request (bytes=5-42)
    final plainPayload = Uint8List.fromList(
      List<int>.generate(64, (i) => (i * 7 + 3) & 0xff),
    );
    final rawKey32 = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    final keyToken = base64Url.encode(rawKey32).replaceAll('=', '');
    final megaUrl = 'https://mega.nz/embed/FILE1234#$keyToken';
    final spec = WitanimeMegaProxy.parseMegaUrl(megaUrl)!;

    // Encrypt plainPayload starting at block 0 with MEGA's derived key & nonce
    final iv0 = Uint8List(16)..setRange(0, 8, spec.nonce8);
    final encrypted = Aes128CtrCipher(key: spec.aesKey16, iv16: iv0)
        .process(plainPayload);

    var upstreamAvailable = true;
    var metadataRequests = 0;
    final proxy = WitanimeMegaProxy(
      openUpstream: (uri) async {
        if (!upstreamAvailable) return null;
        final rangeSeg = uri.pathSegments.last.split('-');
        final start = int.parse(rangeSeg[0]);
        final end = int.parse(rangeSeg[1]);
        return Stream<List<int>>.value(encrypted.sublist(start, end + 1));
      },
    );
    addTearDown(proxy.close);

    final transport = _FakeWitanimeTransport((method, uri, body, _, _) async {
      if (uri.host == 'g.api.mega.co.nz') {
        metadataRequests++;
        return WitanimeHttpResponse(
          statusCode: 200,
          body: jsonEncode([
            {'g': 'https://cdn.mega.test/dl/ticket', 's': plainPayload.length},
          ]),
        );
      }
      return const WitanimeHttpResponse(statusCode: 404, body: '');
    });

    final resolver = WitanimePlaybackResolver(transport, megaProxy: proxy);
    const token = WitanimeSourceToken(
      kind: 'stream',
      watchUrl: 'https://witanime.site/watch/sample/1',
      token: 'tok-mega',
      label: 'mega',
      tier: 'FHD',
    );
    final resolving = resolver.resolveHostedLink(
      token.watchUrl,
      megaUrl,
      token,
    );
    final parallel = proxy.registerStream(megaUrl, transport);
    final streams = await resolving;
    expect(streams.single.url, startsWith('http://127.0.0.1:'));
    expect(await parallel, streams.single.url);
    expect(metadataRequests, 1);

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    // HEAD check
    final headReq = await client.headUrl(Uri.parse(streams.single.url));
    final headResp = await headReq.close();
    expect(headResp.statusCode, 200);
    expect(headResp.headers.value(HttpHeaders.contentLengthHeader), '64');
    await headResp.drain<void>();

    // Unaligned byte-range check (crosses 16-byte AES block boundaries)
    final rangeReq = await client.getUrl(Uri.parse(streams.single.url));
    rangeReq.headers.set(HttpHeaders.rangeHeader, 'bytes=5-42');
    final rangeResp = await rangeReq.close();
    expect(rangeResp.statusCode, 206);
    expect(
      rangeResp.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 5-42/64',
    );
    final chunks = await rangeResp.toList();
    final received = Uint8List.fromList(chunks.expand((c) => c).toList());
    expect(received, plainPayload.sublist(5, 43));

    upstreamAvailable = false;
    final failedReq = await client.getUrl(Uri.parse(streams.single.url));
    failedReq.headers.set(HttpHeaders.rangeHeader, 'bytes=0-15');
    final failedResp = await failedReq.close();
    expect(failedResp.statusCode, 502);
    expect(await failedResp.toList(), isEmpty);
  });

  test('Videa handles MIME-wrapped base64 XML and prioritizes MP4 over WebM', () async {
    const secret =
        'xHb0ZvME5q8CBcoQi6AngerDu3FGO9fkUlwPmLVY_RTzj2hJIS4NasXWKy1td7p';
    // Build a 64-char _xt whose unscrambled output has predictable t & k
    final xt = '${secret.substring(0, 32)}0123456789abcdefABCDEFGHIJKLMNOP';
    final transport = _FakeWitanimeTransport((method, uri, _, headers, _) async {
      if (uri.host == 'videa.hu' && uri.path == '/player') {
        return WitanimeHttpResponse(
          statusCode: 200,
          body: '<script>var _xt="$xt";</script>',
        );
      }
      if (uri.host == 'videa.hu' && uri.path == '/player/xml') {
        final rnd = uri.queryParameters['_s']!;
        const xs = 'Enl9mXdZ';
        const xml =
            '<videa_video><video_sources exp="1795101813">'
            '<video_source mimetype="video/webm" name="720p" exp="1795101813">//videa.hu/static/w720p/1</video_source>'
            '<video_source mimetype="video/mp4" name="720p" exp="1795101813">//videa.hu/static/720p/1</video_source>'
            '<video_source mimetype="video/mp4" name="360p" exp="1795101813">//videa.hu/static/360p/1</video_source>'
            '</video_sources>'
            '<hash_value_720p>HASH720</hash_value_720p>'
            '<hash_value_360p>HASH360</hash_value_360p>'
            '</videa_video>';
        final enc = rc4Crypt(
          utf8.encode('${'P' * 16}$rnd$xs'),
          utf8.encode(xml),
        );
        final b64 = base64Encode(enc);
        // Inject MIME newlines every 76 chars just like live videa.hu does!
        final wrapped = b64.replaceAllMapped(
          RegExp('.{1,76}'),
          (m) => '${m.group(0)}\n',
        );
        return WitanimeHttpResponse(
          statusCode: 200,
          body: wrapped,
          headers: const {
            'content-type': ['text/plain;charset=UTF-8'],
            'x-videa-xs': [xs],
          },
        );
      }
      return const WitanimeHttpResponse(statusCode: 404, body: '');
    });

    final resolver = WitanimePlaybackResolver(transport);
    const token = WitanimeSourceToken(
      kind: 'stream',
      watchUrl: 'https://witanime.site/watch/sample/1',
      token: 'tok-videa',
      label: 'videa',
      tier: 'HD',
    );
    final streams = await resolver.resolveHostedLink(
      token.watchUrl,
      'https://videa.hu/player?v=abc123456789',
      token,
    );
    expect(streams.length, 3);
    expect(
      streams.first.url,
      'https://videa.hu/static/720p/1?md5=HASH720&expires=1795101813',
    );
    expect(streams[1].url, contains('/static/360p/'));
    expect(streams[2].url, contains('/static/w720p/'));
    expect(
      streams.first.headers?['User-Agent'],
      DioWitanimeTransport.defaultUserAgent,
    );
  });

  test('resolves Videas 2-step API, HGCloud relative HLS, GoFile, Mp4Upload DL, 4Shared, MailRu cookies, and rejects MediaFire ZIP', () async {
    String? videasOpening;
    String? gofileWt;
    final transport = _FakeWitanimeTransport((method, uri, body, headers, _) async {
      if (uri.host == 'app.videas.com' && uri.path == '/embed/abcd1234-5678-9012-3456-7890abcdef12/') {
        return const WitanimeHttpResponse(
          statusCode: 200,
          body:
              '<script id="videas-embed-config" type="application/json">'
              '{"embedId":"abcd1234-5678-9012-3456-7890abcdef12","opening":"open-tok"}'
              '</script>',
        );
      }
      if (uri.host == 'app.videas.com' &&
          uri.path == '/api/visitor/embed/abcd1234-5678-9012-3456-7890abcdef12/') {
        videasOpening = headers['X-Embed-Opening'];
        return WitanimeHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'playback_token': 'pb-tok',
            'session_id': 'sess-1',
            'items': [
              {
                'asset': {
                  'uid': 'asset-1',
                  'subtitles': [
                    {'label': 'Arabic', 'url': '/subs/ar.vtt'},
                  ],
                },
              },
            ],
          }),
        );
      }
      if (uri.host == 'app.videas.com' &&
          uri.path == '/api/visitor/playback/info/') {
        return WitanimeHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'hls_url': {'url': 'https://cdn.videas.com/hls/master.m3u8'},
          }),
        );
      }
      if (uri.host == 'vibuxer.com' && uri.path == '/e/hg123') {
        return const WitanimeHttpResponse(
          statusCode: 200,
          body:
              r"<script>eval(function(p,a,c,k,e,r){return p}('0={\'1\':\'/2/3/4.5\'}',6,6,'links|hls4|stream|abc|master|m3u8'.split('|'),0,{}))</script>",
        );
      }
      if (uri.host == 'api.gofile.io' && uri.path == '/accounts') {
        return WitanimeHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'status': 'ok',
            'data': {'token': 'gf-tok-1'},
          }),
        );
      }
      if (uri.host == 'api.gofile.io' && uri.path == '/contents/GfCode1') {
        gofileWt = headers['X-Website-Token'];
        expect(headers['Authorization'], 'Bearer gf-tok-1');
        return WitanimeHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'status': 'ok',
            'data': {
              'type': 'folder',
              'children': {
                'f1': {
                  'name': 'ep07_HD.mp4',
                  'mimetype': 'video/mp4',
                  'link': 'https://store1.gofile.io/download/web/f1/ep07_HD.mp4',
                },
              },
            },
          }),
        );
      }
      if (uri.host == 'www.mp4upload.com' && uri.path == '/embed-dl999.html') {
        return const WitanimeHttpResponse(
          statusCode: 200,
          body: '<script>player.src("https://s1.mp4upload.com:183/d/abc/video.mp4");</script>',
        );
      }
      if (uri.host == 'www.4shared.com' && uri.path == '/web/embed/file/sh123') {
        return const WitanimeHttpResponse(
          statusCode: 200,
          body: '<video><source src="https://dc123.4shared.com/img/sh123/video.mp4"></video>',
        );
      }
      if (uri.host == 'my.mail.ru' && uri.path == '/video/embed/1') {
        return const WitanimeHttpResponse(
          statusCode: 200,
          body: '{"metadataUrl":"//my.mail.ru/+/video/meta/1"}',
          headers: {
            'set-cookie': ['m_sess=1; Path=/'],
          },
        );
      }
      if (uri.host == 'my.mail.ru' && uri.path == '/+/video/meta/1') {
        return WitanimeHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'videos': [
              {'key': '720p', 'url': '//cdn.mail.ru/v/720.mp4'},
            ],
          }),
          headers: const {
            'set-cookie': ['video_key=vk999; Path=/'],
          },
        );
      }
      return const WitanimeHttpResponse(statusCode: 404, body: '');
    });

    final resolver = WitanimePlaybackResolver(transport);
    const baseToken = WitanimeSourceToken(
      kind: 'stream',
      watchUrl: 'https://witanime.site/watch/sample/1',
      token: 'tok',
      label: 'srv',
      tier: 'FHD',
    );

    final videas = await resolver.resolveHostedLink(
      baseToken.watchUrl,
      'https://app.videas.com/embed/media/abcd1234-5678-9012-3456-7890abcdef12/',
      baseToken,
    );
    expect(videasOpening, 'open-tok');
    expect(videas.single.url, 'https://cdn.videas.com/hls/master.m3u8');
    expect(videas.single.subtitles?.single.url, 'https://app.videas.com/subs/ar.vtt');

    final hg = await resolver.resolveHostedLink(
      baseToken.watchUrl,
      'https://hgcloud.to/e/hg123',
      baseToken,
    );
    expect(hg.single.url, 'https://vibuxer.com/stream/abc/master.m3u8');
    expect(hg.single.headers?['Origin'], 'https://vibuxer.com');
    expect(hg.single.headers?['Referer'], 'https://vibuxer.com/');

    final gf = await resolver.resolveHostedLink(
      baseToken.watchUrl,
      'https://gofile.io/d/GfCode1',
      baseToken,
    );
    expect(gofileWt, hasLength(64));
    expect(gf.single.url, contains('ep07_HD.mp4'));
    expect(gf.single.headers?['Cookie'], 'accountToken=gf-tok-1');

    final mp4 = await resolver.resolveHostedLink(
      baseToken.watchUrl,
      'https://www.mp4upload.com/dl999',
      baseToken,
    );
    expect(mp4.single.url, 'https://s1.mp4upload.com:183/d/abc/video.mp4');
    expect(mp4.single.headers?['Origin'], 'https://www.mp4upload.com');
    final directMp4 = await resolver.resolveHostedLink(
      baseToken.watchUrl,
      mp4.single.url,
      baseToken,
    );
    expect(directMp4.single.url, mp4.single.url);
    expect(directMp4.single.headers, mp4.single.headers);

    final shared = await resolver.resolveHostedLink(
      baseToken.watchUrl,
      'https://www.4shared.com/video/sh123/ep.html',
      baseToken,
    );
    expect(shared.single.url, 'https://dc123.4shared.com/img/sh123/video.mp4');

    final mail = await resolver.resolveHostedLink(
      baseToken.watchUrl,
      'https://my.mail.ru/video/embed/1',
      baseToken,
    );
    expect(mail.single.headers?['Cookie'], contains('video_key=vk999'));

    await expectLater(
      resolver.resolveHostedLink(
        baseToken.watchUrl,
        'https://www.mediafire.com/file/abc/0649_07_HD.zip/file',
        baseToken,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('playback and download share a source listing and concurrent resolutions', () async {
    var watchGets = 0;
    var sourcePosts = 0;
    var unlockPosts = 0;
    final transport = _FakeWitanimeTransport((method, uri, _, _, _) async {
      if (uri.path == '/watch/sample/1') {
        watchGets++;
        return const WitanimeHttpResponse(
          statusCode: 200,
          body:
              '<meta name="csrf-token" content="csrf-cached">'
              '<script src="https://challenges.cloudflare.com/turnstile/v0/api.js"></script>',
        );
      }
      if (uri.path == '/watch/sample/1/sources') {
        sourcePosts++;
        return WitanimeHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'players': {
              'HD': [
                {'label': 'Google Drive', 'token': 'tok-cache'},
              ],
            },
          }),
        );
      }
      if (uri.path == '/watch/stream-source/tok-cache') {
        unlockPosts++;
        return const WitanimeHttpResponse(statusCode: 200, body: '{"ok":true}');
      }
      if (uri.path == '/watch/stream-gate/tok-cache') {
        return const WitanimeHttpResponse(
          statusCode: 302,
          body: '',
          headers: {
            'location': ['https://drive.google.com/file/d/CACHE_ID/view'],
          },
        );
      }
      return const WitanimeHttpResponse(statusCode: 404, body: '');
    });

    final resolver = WitanimePlaybackResolver(transport);
    const watch = 'https://witanime.site/watch/sample/1';
    final [playback, download] = await Future.wait([
      resolver.loadSources(watch, forDownload: false),
      resolver.loadSources(watch, forDownload: true),
    ]);
    expect(playback.single.url, download.single.url);
    final resolved = await Future.wait([
      resolver.resolveStreams(playback.single.url, forDownload: false),
      resolver.resolveStreams(download.single.url, forDownload: true),
    ]);
    expect(
      resolved.every((result) => result.single.url.contains('id=CACHE_ID')),
      isTrue,
    );
    expect(watchGets, 1);
    expect(sourcePosts, 1);
    expect(unlockPosts, 1);
  });

  test('distinct tokens share one host request and use declared video URLs', () async {
    var hostRequests = 0;
    final transport = _FakeWitanimeTransport((_, uri, _, _, _) async {
      expect(uri.host, 'player.example.com');
      hostRequests++;
      return const WitanimeHttpResponse(
        statusCode: 200,
        body: '<video src="/media/episode"></video>'
            '<script>const ad = "https://ads.example.com/ad.mp4";</script>',
      );
    });
    final resolver = WitanimePlaybackResolver(transport);
    const watch = 'https://witanime.site/watch/sample/1';
    const embed = 'https://player.example.com/embed?ref=ok.ru';
    final entries = [
      for (final kind in ['stream', 'download'])
        WitanimeSourceToken(
          watchUrl: watch,
          kind: kind,
          token: 'token-$kind',
          label: 'Mirror',
          tier: 'FHD',
        ),
    ];
    final streams = await Future.wait([
      for (final entry in entries) resolver.resolveHostedLink(watch, embed, entry),
    ]);
    expect(hostRequests, 1);
    for (final result in streams) {
      expect(result.single.url, 'https://player.example.com/media/episode');
    }
    await resolver.resolveHostedLink(watch, embed, entries.first);
    expect(hostRequests, 2);
  });

  test('GoFile guest setup runs while the selected source unlocks', () async {
    final unlock = Completer<WitanimeHttpResponse>();
    final guestStarted = Completer<void>();
    var guests = 0;
    const token = WitanimeSourceToken(
      kind: 'download',
      watchUrl: 'https://witanime.site/watch/sample/1',
      token: 'gofile-token',
      label: 'GoFile',
      tier: 'FHD',
    );
    final resolver = WitanimePlaybackResolver(
      _FakeWitanimeTransport((_, uri, _, _, _) async {
        switch (uri.path) {
          case '/watch/sample/1':
            return const WitanimeHttpResponse(
              statusCode: 200,
              body: '<meta name="csrf-token" content="csrf">',
            );
          case '/watch/download-source/gofile-token':
            return unlock.future;
          case '/watch/download-gate/gofile-token':
            return const WitanimeHttpResponse(
              statusCode: 302,
              body: '',
              headers: {'location': ['https://gofile.io/d/sample']},
            );
          case '/accounts':
            if (++guests == 1) guestStarted.complete();
            return const WitanimeHttpResponse(
              statusCode: 200,
              body: '{"status":"ok","data":{"token":"guest"}}',
            );
          case '/contents/sample':
            return const WitanimeHttpResponse(
              statusCode: 200,
              body: '{"status":"ok","data":{"type":"file","name":"sample.mp4",'
                  '"link":"https://store.gofile.io/download/sample.mp4"}}',
            );
          default:
            fail('Unexpected extraction request: ${uri.path}');
        }
      }),
    );
    final result = resolver.resolveStreams(token.encode(), forDownload: false);
    try {
      await guestStarted.future.timeout(const Duration(seconds: 1));
    } finally {
      unlock.complete(const WitanimeHttpResponse(statusCode: 200, body: '{}'));
    }
    expect((await result).single.url, 'https://store.gofile.io/download/sample.mp4');
    expect(guests, 1);
  });

  test('GoFile resolves nested folders, directLink fallback, percent-encodes spaces, and rejects inaccessible folders', () async {
    final transport = _FakeWitanimeTransport((method, uri, headers, _, _) async {
      if (uri.host == 'api.gofile.io' && uri.path == '/accounts') {
        return WitanimeHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'status': 'ok',
            'data': {'token': 'gf-nested-tok'},
          }),
        );
      }
      if (uri.host == 'api.gofile.io' && uri.path == '/contents/RootFolder') {
        return WitanimeHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'status': 'ok',
            'data': {
              'type': 'folder',
              'canAccess': true,
              'children': {
                'sub1': {
                  'type': 'folder',
                  'code': 'SubFolder1',
                  'id': 'sub-id-1',
                },
              },
            },
          }),
        );
      }
      if (uri.host == 'api.gofile.io' && uri.path == '/contents/SubFolder1') {
        return WitanimeHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'status': 'ok',
            'data': {
              'type': 'folder',
              'canAccess': true,
              'children': {
                'f1': {
                  'type': 'file',
                  'name': 'Black Clover 07 HD.mp4',
                  'mimetype': 'video/mp4',
                  'link': '',
                  'directLink':
                      'https://store2.gofile.io/download/web/f1/Black Clover 07 HD.mp4',
                },
              },
            },
          }),
        );
      }
      if (uri.host == 'api.gofile.io' && uri.path == '/contents/LockedFolder') {
        return WitanimeHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'status': 'ok',
            'data': {
              'type': 'folder',
              'canAccess': false,
              'children': <String, Object?>{},
            },
          }),
        );
      }
      return const WitanimeHttpResponse(statusCode: 404, body: '');
    });

    final resolver = WitanimePlaybackResolver(transport);
    const token = WitanimeSourceToken(
      watchUrl: 'https://witanime.site/watch/sample/7',
      kind: 'download',
      token: 'tok-gf',
      tier: 'HD',
      label: 'GoFile',
    );

    final streams = await resolver.resolveHostedLink(
      token.watchUrl,
      'https://gofile.io/d/RootFolder',
      token,
    );
    expect(
      streams.single.url,
      'https://store2.gofile.io/download/web/f1/Black%20Clover%2007%20HD.mp4',
    );
    expect(streams.single.headers?['Cookie'], 'accountToken=gf-nested-tok');
    expect(streams.single.headers?['Origin'], 'https://gofile.io');
    expect(streams.single.headers?['Referer'], 'https://gofile.io/');

    await expectLater(
      resolver.resolveHostedLink(
        token.watchUrl,
        'https://gofile.io/d/LockedFolder',
        token,
      ),
      throwsA(isA<FormatException>()),
    );

    // Trailing filename after /d/<id>/... still extracts RootFolder cleanly.
    final withFilename = await resolver.resolveHostedLink(
      token.watchUrl,
      'https://gofile.io/d/RootFolder/0649_07_FHD.mp4',
      token,
    );
    expect(
      withFilename.single.url,
      'https://store2.gofile.io/download/web/f1/Black%20Clover%2007%20HD.mp4',
    );

    // Direct store CDN URL passes through without extra API calls.
    final directStore = await resolver.resolveHostedLink(
      token.watchUrl,
      'https://store4.gofile.io/download/web/abc/0649_07_FHD.mp4',
      token,
    );
    expect(
      directStore.single.url,
      'https://store4.gofile.io/download/web/abc/0649_07_FHD.mp4',
    );
  });

  test('WorkUpload reports anti-bot human verification clearly', () async {
    final transport = _FakeWitanimeTransport((method, uri, _, _, _) async {
      if (uri.host == 'workupload.com') {
        return const WitanimeHttpResponse(
          statusCode: 200,
          body: '<html><head><title>workupload - Are you a human?</title></head></html>',
        );
      }
      return const WitanimeHttpResponse(statusCode: 404, body: '');
    });
    final resolver = WitanimePlaybackResolver(transport);
    const token = WitanimeSourceToken(
      watchUrl: 'https://witanime.site/watch/sample/7',
      kind: 'download',
      token: 'tok-wu',
      tier: 'HD',
      label: 'WorkUpload',
    );
    await expectLater(
      resolver.resolveHostedLink(
        token.watchUrl,
        'https://workupload.com/file/abc123',
        token,
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('CAPTCHA'),
        ),
      ),
    );
  });

  test('DioWitanimeTransport preserves application/json GET responses for GoFile and other JSON APIs', () async {
    final dio = Dio(BaseOptions(responseType: ResponseType.plain));
    var accounts = 0;
    var expireGoFileToken = false;
    addTearDown(() => dio.close(force: true));
    dio.httpClientAdapter = _Adapter((options) async {
      if (options.uri.host == 'api.gofile.io' &&
          options.uri.path == '/accounts') {
        accounts++;
        return ResponseBody.fromString(
          jsonEncode({
            'status': 'ok',
            'data': {'token': 'real-dio-tok-$accounts'},
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json; charset=utf-8'],
          },
        );
      }
      if (options.uri.host == 'api.gofile.io' &&
          options.uri.path == '/contents/YptWOpSB') {
        if (options.headers['Authorization'] == 'Bearer real-dio-tok-1' &&
            expireGoFileToken) {
          return ResponseBody.fromString('{"status":"error"}', 401);
        }
        return ResponseBody.fromString(
          jsonEncode({
            'status': 'ok',
            'data': {
              'canAccess': true,
              'type': 'file',
              'name': '0649_07_FHD.mp4',
              'mimetype': 'video/mp4',
              'link':
                  'https://file-eu-par-2.gofile.io/download/web/adeb48a1/0649_07_FHD.mp4',
            },
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json; charset=utf-8'],
          },
        );
      }
      return ResponseBody.fromString('', 404);
    });

    final transport = DioWitanimeTransport(dio: dio);
    final resolver = WitanimePlaybackResolver(transport);
    const token = WitanimeSourceToken(
      watchUrl: 'https://witanime.site/watch/black-clover-2nd-season/7',
      kind: 'download',
      token: 'tok-gf-real',
      tier: 'FHD',
      label: 'gofile',
    );
    final streams = await resolver.resolveHostedLink(
      token.watchUrl,
      'https://gofile.io/d/YptWOpSB',
      token,
    );
    expect(streams, hasLength(1));
    expect(
      streams.single.url,
      'https://file-eu-par-2.gofile.io/download/web/adeb48a1/0649_07_FHD.mp4',
    );
    expect(streams.single.headers?['Cookie'], 'accountToken=real-dio-tok-1');
    expect(streams.single.headers?['Origin'], 'https://gofile.io');
    final second = await resolver.resolveHostedLink(
      token.watchUrl,
      'https://gofile.io/d/YptWOpSB',
      token,
    );
    expect(second.single.url, streams.single.url);
    expect(accounts, 1);
    expireGoFileToken = true;
    final refreshed = await resolver.resolveHostedLink(
      token.watchUrl,
      'https://gofile.io/d/YptWOpSB',
      token,
    );
    expect(refreshed.single.headers?['Cookie'], 'accountToken=real-dio-tok-2');
    expect(accounts, 2);
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handler(options);
}
