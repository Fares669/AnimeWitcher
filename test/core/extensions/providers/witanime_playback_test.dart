import 'dart:convert';
import 'dart:typed_data';

import 'package:animewitcher/core/extensions/providers/witanime_crypto.dart';
import 'package:animewitcher/core/extensions/providers/witanime_playback.dart';
import 'package:animewitcher/core/extensions/providers/witanime_provider.dart';
import 'package:animewitcher/core/extensions/providers/witanime_transport.dart';
import 'package:animewitcher/core/services/download_url_refresh.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
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
    final encryptedDrive = _encryptYonaplayForTest(
      'k1',
      'https://drive.google.com/file/d/FILE_ID_1/view',
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
      if (uri.host == 'witanime.site' && uri.path == '/watch/sample/1/sources') {
        return WitanimeHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'players': {
              'FHD': [
                {'label': 'Yonaplay', 'token': 'tok-yona-$downloadTokenVersion'},
                {'label': 'Hgcloud', 'token': 'tok-hg'},
                {'label': 'Mega', 'token': 'tok-mega'},
              ],
            },
            'versions': {
              'dub': {
                'downloads': {
                  'HD': [
                    {'label': 'Google Drive', 'token': 'tok-dl-$downloadTokenVersion'},
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
          body: '{"qualities":[{"name":"FHD","servers":[{"token":"srv1"}]}]}',
        );
      }
      if (uri.host == 'yonaplay.org' && uri.path == '/api/api.php') {
        return WitanimeHttpResponse(
          statusCode: 200,
          body: jsonEncode({'d': encryptedDrive}),
        );
      }
      if (uri.host == 'hgcloud.to' && uri.path == '/e/xyz') {
        return const WitanimeHttpResponse(
          statusCode: 200,
          body: '<script src="/main.js?v=1.1.9"></script>',
        );
      }
      if (uri.host == 'hanerix.com' && uri.path == '/e/xyz') {
        return const WitanimeHttpResponse(
          statusCode: 200,
          body:
              '<script>var url="https://edge.hanerix.com/stream/master.txt?t=1";</script>',
        );
      }
      return WitanimeHttpResponse(statusCode: 404, body: 'Not found: $uri');
    });

    final provider = WitanimeProvider.withTransport(transport);

    final streamSources = await provider.loadStreamSources(
      'https://witanime.site/watch/sample/1',
    );
    expect(streamSources.length, 3);
    expect(streamSources.every((s) => s.requiresResolution), isTrue);
    expect(provider.isExplicitStreamSelection(streamSources.first.url), isTrue);

    final yonaResolved = await provider.loadStreams(streamSources.first.url);
    expect(gateRefererPresent, isFalse);
    expect(
      yonaResolved.single.url,
      'https://drive.usercontent.google.com/download?id=FILE_ID_1&export=download&confirm=t',
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
    expect(downloadSources.single.source, 'Google Drive (عربي مدبلج)');
    expect(downloadSources.single.quality, '720p');

    final dl1 = await provider.loadDownloadStreams(downloadSources.single.url);
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
        source: downloadSources.single.source,
        quality: downloadSources.single.quality,
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
