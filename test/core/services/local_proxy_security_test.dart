import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/local_proxy_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Headers extends Fake implements HttpHeaders {
  final values = <String, List<String>>{};
  @override
  List<String>? operator [](String name) => values[name.toLowerCase()];
  @override
  String? value(String name) => this[name]?.join(', ');
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      values.putIfAbsent(name.toLowerCase(), () => []).add('$value');
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = ['$value'];
  @override
  void removeAll(String name) => values.remove(name.toLowerCase());
  @override
  void forEach(void Function(String, List<String>) action) =>
      values.forEach(action);
  @override
  ContentType? get contentType {
    final raw = value('content-type');
    return raw == null ? null : ContentType.parse(raw);
  }
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(
    this.statusCode, {
    String? location,
    this.body = 'media',
    String? type,
  }) {
    if (location != null) headers.set('location', location);
    if (type != null) headers.set('content-type', type);
  }
  @override
  final int statusCode;
  final String body;
  bool consumed = false;
  @override
  final _Headers headers = _Headers();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    consumed = true;
    return Stream.value(utf8.encode(body)).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.uri, this.response);
  @override
  final Uri uri;
  final _Response response;
  @override
  final _Headers headers = _Headers();
  @override
  bool followRedirects = true;
  @override
  Future<HttpClientResponse> close() async => response;
}

class _Client extends Fake implements HttpClient {
  _Client(this.responses);
  final List<_Response> responses;
  final requests = <_Request>[];
  bool closed = false;
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 30);
  @override
  bool autoUncompress = false;
  @override
  bool Function(X509Certificate, String, int)? badCertificateCallback;
  @override
  Future<ConnectionTask<Socket>> Function(Uri, String?, int?)?
  connectionFactory;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final request = _Request(url, responses[requests.length]);
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) => closed = true;
}

class _Socket extends Fake implements Socket {}

void main() {
  var service = LocalProxyService.instance;
  late HttpClient inbound;

  setUp(() {
    service = LocalProxyService.instance;
    inbound = HttpClient();
  });
  tearDown(() async {
    inbound.close(force: true);
    await service.shutdown();
  });

  Future<({int status, String body})> fetch(
    _Client upstream,
    String target, {
    Map<String, String>? headers,
    ProxyOptions? options,
  }) async {
    return HttpOverrides.runZoned(() async {
      await service.startServer();
      final request = await inbound.getUrl(
        Uri.parse(
          service.getProxyUrl(target, headers: headers, options: options),
        ),
      );
      final response = await request.close();
      return (
        status: response.statusCode,
        body: await utf8.decoder.bind(response).join(),
      );
    }, createHttpClient: (_) => upstream);
  }

  for (final host in ['example.com', 'cdn.example.com', 'not-example.com']) {
    test('mirror cookie scope uses DNS boundaries for $host', () async {
      service = LocalProxyService.forTesting(
        (_) async => [InternetAddress('8.8.8.8')],
      );
      final upstream = _Client([_Response(200)]);
      final response = await fetch(
        upstream,
        'https://$host/video',
        headers: {'Cookie': 'session=private'},
        options: ProxyOptions(mirrorHosts: ['example.com']),
      );
      expect(response.status, 200);
      expect(
        upstream.requests.single.headers.value('cookie'),
        host == 'not-example.com' ? isNull : 'session=private',
      );
    });
  }
  test('lookalike playlist host cannot inherit a signed query', () async {
    service = LocalProxyService.forTesting(
      (_) async => [InternetAddress('8.8.8.8')],
    );
    final upstream = _Client([
      _Response(
        200,
        type: 'application/vnd.apple.mpegurl',
        body: '#EXTM3U\nhttps://not-example.com/segment.ts\n',
      ),
    ]);
    final result = await fetch(
      upstream,
      'https://example.com/master.m3u8?token=PRIVATE',
      options: ProxyOptions(mirrorHosts: ['example.com']),
    );
    final child = Uri.parse(result.body.split('\n')[1]);
    expect(Uri.parse(child.queryParameters['url']!).hasQuery, isFalse);
  });

  for (final host in [
    '127.0.0.1',
    '127.1',
    '2130706433',
    '10.1.2.3',
    '172.16.0.1',
    '192.168.1.1',
    '169.254.169.254',
    '100.64.0.1',
    '0.0.0.0',
    '[::1]',
    '[::]',
    '[fc00::1]',
    '[fe80::1]',
    '[::ffff:127.0.0.1]',
    '[::ffff:192.168.1.1]',
    '[64:ff9b::7f00:1]',
    '[64:ff9b::a9fe:a9fe]',
    'localhost',
  ]) {
    test(
      'blocks non-public initial target $host before upstream open',
      () async {
        final upstream = _Client([_Response(200)]);
        final result = await fetch(upstream, 'http://$host/video');
        expect(result.status, anyOf(400, 403, 502));
        expect(upstream.requests, isEmpty);
      },
    );
  }

  for (final location in [
    'http://127.0.0.1/private',
    '//192.168.1.1/private',
    'http://[::ffff:169.254.169.254]/metadata',
    'file:///etc/passwd',
    'http://user:secret@8.8.8.8/private',
    'http://localhost/private',
  ]) {
    test('validates redirect before opening $location', () async {
      final redirect = _Response(302, location: location);
      final upstream = _Client([redirect, _Response(200)]);
      final result = await fetch(upstream, 'http://8.8.8.8/start');
      expect(result.status, anyOf(400, 403, 502));
      expect(upstream.requests, hasLength(1));
      expect(redirect.consumed, isTrue);
      expect(upstream.closed, isTrue);
    });
  }

  test(
    'same-origin relative redirect preserves credentials and range',
    () async {
      final upstream = _Client([
        _Response(307, location: '../next'),
        _Response(200),
      ]);
      final result = await fetch(
        upstream,
        'https://8.8.8.8/path/start',
        headers: {
          'Authorization': 'Bearer same-origin',
          'Cookie': 'session=keep',
          'Range': 'bytes=10-',
        },
        options: ProxyOptions(mirrorHosts: ['8.8.8.8']),
      );
      expect(result.status, 200);
      expect(upstream.requests.last.uri.toString(), 'https://8.8.8.8/next');
      expect(
        upstream.requests.last.headers.value('authorization'),
        'Bearer same-origin',
      );
      expect(upstream.requests.last.headers.value('cookie'), 'session=keep');
      expect(upstream.requests.last.headers.value('range'), 'bytes=10-');
      expect(upstream.requests.every((r) => !r.followRedirects), isTrue);
      expect(upstream.responses.first.consumed, isTrue);
      expect(upstream.closed, isTrue);
    },
  );

  for (final destination in [
    'https://1.1.1.1/next',
    'http://8.8.8.8/next',
    'https://8.8.8.8:444/next',
  ]) {
    test(
      'cross-origin strips secrets without restoring them: $destination',
      () async {
        final upstream = _Client([
          _Response(302, location: destination),
          _Response(303, location: '/last'),
          _Response(200),
        ]);
        final result = await fetch(
          upstream,
          'https://8.8.8.8/start',
          headers: {
            'Authorization': 'Bearer private',
            'Proxy-Authorization': 'Basic private',
            'Cookie': 'session=private',
            'X-Api-Key': 'private',
            'X-Custom-Credential': 'private',
            'Origin': 'https://private.test',
            'Referer': 'https://private.test/?token=private',
            'Range': 'bytes=10-',
            'User-Agent': 'Player test',
          },
          options: ProxyOptions(
            mirrorHosts: ['8.8.8.8', '1.1.1.1'],
            keepCookies: ['session'],
            referer: 'https://private.test/?token=private',
          ),
        );
        expect(result.status, 200);
        for (final hop in upstream.requests.skip(1)) {
          expect(hop.headers.values.toString(), isNot(contains('private')));
          expect(hop.headers.value('cookie'), isNull);
          expect(hop.headers.value('range'), 'bytes=10-');
          expect(hop.headers.value('user-agent'), 'Player test');
        }
      },
    );
  }

  test('child proxy strips credential headers across playlist origins', () {
    final proxy = Uri.parse(
      service.getChildProxyUrl(
        'https://1.1.1.1/audio.m3u8',
        parentUrl: Uri.parse('https://8.8.8.8/master.m3u8'),
        headers: const {
          'Authorization': 'Bearer secret',
          'Cookie': 'session=secret',
          'X-Api-Key': 'secret',
          'Range': 'bytes=10-',
          'User-Agent': 'Player test',
        },
        options: ProxyOptions(
          mirrorHosts: const ['8.8.8.8', '1.1.1.1'],
          keepCookies: const ['session'],
          referer: 'https://8.8.8.8/master.m3u8',
        ),
      ),
    );

    final encodedHeaders = proxy.queryParameters['h'];
    expect(encodedHeaders, isNotNull);
    final decodedHeaders = jsonDecode(
      utf8.decode(base64Url.decode(encodedHeaders!)),
    ) as Map<String, dynamic>;
    expect(decodedHeaders['Authorization'], isNull);
    expect(decodedHeaders['Cookie'], isNull);
    expect(decodedHeaders['X-Api-Key'], isNull);
    expect(decodedHeaders['Range'], 'bytes=10-');
    expect(decodedHeaders['User-Agent'], 'Player test');
    expect(proxy.queryParameters['o'], isNull);
    expect(proxy.queryParameters['s'], '1');
  });

  test('child proxy retains playlist credentials on the same origin', () {
    final proxy = Uri.parse(
      service.getChildProxyUrl(
        'https://8.8.8.8/audio.m3u8',
        parentUrl: Uri.parse('https://8.8.8.8/master.m3u8'),
        headers: const {
          'Authorization': 'Bearer same-origin',
          'Cookie': 'session=keep',
        },
        options: ProxyOptions(
          mirrorHosts: const ['8.8.8.8'],
          keepCookies: const ['session'],
        ),
      ),
    );

    final decodedHeaders = jsonDecode(
      utf8.decode(base64Url.decode(proxy.queryParameters['h']!)),
    ) as Map<String, dynamic>;
    expect(decodedHeaders['Authorization'], 'Bearer same-origin');
    expect(decodedHeaders['Cookie'], 'session=keep');
    expect(proxy.queryParameters['o'], isNotNull);
    expect(proxy.queryParameters['s'], isNull);
  });

  test(
    'redirected playlist uses final base and cannot re-embed old secrets',
    () async {
      final upstream = _Client([
        _Response(302, location: 'https://1.1.1.1/other/master.m3u8'),
        _Response(
          200,
          type: 'application/vnd.apple.mpegurl',
          body: '#EXTM3U\nsegment.ts\n',
        ),
        _Response(200),
      ]);
      final result = await fetch(
        upstream,
        'https://8.8.8.8/original/master.m3u8',
        headers: {
          'Authorization': 'Bearer private',
          'Cookie': 'session=private',
        },
        options: ProxyOptions(keepCookies: ['session']),
      );
      final segment = Uri.parse(result.body.split('\n')[1]);
      expect(
        segment.queryParameters['url'],
        'https://1.1.1.1/other/segment.ts',
      );
      final encoded = segment.queryParameters['h'];
      if (encoded != null) {
        expect(
          utf8.decode(base64Url.decode(encoded)),
          isNot(contains('private')),
        );
      }
      expect(result.status, 200);
      // Native HLS backends may resend the original Media HTTP headers to every
      // local proxy URL, even when the rewritten URL no longer embeds them.
      final child = await inbound.getUrl(segment);
      child.headers.set('Authorization', 'Bearer private');
      child.headers.set('Cookie', 'session=private');
      child.headers.set('X-Custom-Credential', 'private');
      final childResponse = await child.close();
      await childResponse.drain<void>();
      expect(childResponse.statusCode, 200);
      expect(
        upstream.requests.last.headers.values.toString(),
        isNot(contains('private')),
      );
    },
  );

  test(
    'redirect loop stops at the configured hop limit and closes client',
    () async {
      final upstream = _Client(
        List.generate(8, (_) => _Response(308, location: '/again')),
      );
      final result = await fetch(upstream, 'https://8.8.8.8/start');
      expect(result.status, 502);
      expect(upstream.requests.length, lessThanOrEqualTo(6));
      expect(
        upstream.responses
            .take(upstream.requests.length)
            .every((r) => r.consumed),
        isTrue,
      );
      expect(upstream.closed, isTrue);
    },
  );

  for (final addresses in [
    ['127.0.0.1'],
    ['8.8.8.8', '10.0.0.1'],
    ['8.8.8.8', 'fc00::1'],
    <String>[],
  ]) {
    test(
      'rejects DNS answers containing a non-public address: $addresses',
      () async {
        service = LocalProxyService.forTesting(
          (_) async => addresses.map(InternetAddress.new).toList(),
        );
        final upstream = _Client([_Response(200)]);
        final result = await fetch(upstream, 'http://catalog.test/media');
        expect(result.status, 502);
        expect(upstream.requests, isEmpty);
        expect(upstream.closed, isTrue);
      },
    );
  }

  test('DNS failure fails closed before opening an upstream request', () async {
    service = LocalProxyService.forTesting(
      (_) async => throw const SocketException('DNS unavailable'),
    );
    final upstream = _Client([_Response(200)]);
    expect((await fetch(upstream, 'http://catalog.test/media')).status, 502);
    expect(upstream.requests, isEmpty);
  });

  for (final host in ['[2606:4700:4700::1111]', '[64:ff9b::808:808]']) {
    test('permits a public IPv6 destination $host', () async {
      final upstream = _Client([_Response(200)]);
      expect((await fetch(upstream, 'http://$host/media')).status, 200);
      expect(upstream.requests, hasLength(1));
    });
  }

  test('DNS rebinding is rejected again at socket connection time', () async {
    var lookups = 0;
    service = LocalProxyService.forTesting(
      (_) async => [InternetAddress(++lookups == 1 ? '8.8.8.8' : '127.0.0.1')],
    );
    final upstream = _Client([_Response(200)]);
    expect((await fetch(upstream, 'http://catalog.test/media')).status, 200);
    await expectLater(
      upstream.connectionFactory!(
        Uri.parse('http://catalog.test/media'),
        null,
        null,
      ),
      throwsA(isA<SocketException>()),
    );
    expect(lookups, 2);
  });

  test(
    'connector pins the checked IP rather than re-resolving a hostname',
    () async {
      service = LocalProxyService.forTesting(
        (_) async => [InternetAddress('8.8.8.8')],
      );
      final upstream = _Client([_Response(200)]);
      await fetch(upstream, 'http://catalog.test/media');
      Object? connectedHost;
      await IOOverrides.runZoned(
        () async {
          await upstream.connectionFactory!(
            Uri.parse('http://catalog.test/media'),
            null,
            null,
          );
        },
        socketStartConnect:
            (
              dynamic host,
              int port, {
              dynamic sourceAddress,
              int sourcePort = 0,
            }) async {
              connectedHost = host;
              expect(port, 80);
              return ConnectionTask.fromSocket(
                Completer<Socket>().future,
                () {},
              );
            },
      );
      expect(connectedHost, isA<InternetAddress>());
      expect((connectedHost as InternetAddress).address, '8.8.8.8');
    },
  );

  test(
    'returning to the first origin never resurrects its credentials',
    () async {
      final upstream = _Client([
        _Response(302, location: 'https://1.1.1.1/second'),
        _Response(302, location: 'https://8.8.8.8/last'),
        _Response(200),
      ]);
      await fetch(
        upstream,
        'https://8.8.8.8/start',
        headers: {'Authorization': 'Bearer private'},
      );
      expect(upstream.requests.last.headers.value('authorization'), isNull);
    },
  );

  test('connection can retry another checked public address', () async {
    service = LocalProxyService.forTesting(
      (_) async => [InternetAddress('8.8.8.8'), InternetAddress('1.1.1.1')],
    );
    final upstream = _Client([_Response(200)]);
    await fetch(upstream, 'http://catalog.test/media');
    final attempted = <String>[];
    await IOOverrides.runZoned(
      () async {
        final task = await upstream.connectionFactory!(
          Uri.parse('http://catalog.test/media'),
          null,
          null,
        );
        expect(await task.socket, isA<Socket>());
      },
      socketStartConnect:
          (
            dynamic host,
            int port, {
            dynamic sourceAddress,
            int sourcePort = 0,
          }) async {
            attempted.add((host as InternetAddress).address);
            return ConnectionTask.fromSocket(
              attempted.length == 1
                  ? Future<Socket>.delayed(
                      Duration.zero,
                      () => throw const SocketException(
                        'First address unavailable',
                      ),
                    )
                  : Future<Socket>.value(_Socket()),
              () {},
            );
          },
    );
    expect(attempted, ['8.8.8.8', '1.1.1.1']);
  });

  test('HTTPS connector retries another checked address after TLS handshake failure', () async {
    service = LocalProxyService.forTesting(
      (_) async => [InternetAddress('8.8.8.8'), InternetAddress('1.1.1.1')],
    );
    final upstream = _Client([_Response(200)]);
    await fetch(upstream, 'https://catalog.test/media');

    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((socket) {
      socket.add(utf8.encode('not a TLS server'));
      unawaited(socket.flush().whenComplete(socket.destroy));
    });
    final sockets = <Socket>[
      await Socket.connect(InternetAddress.loopbackIPv4, server.port),
      await Socket.connect(InternetAddress.loopbackIPv4, server.port),
    ];
    final attempted = <String>[];

    try {
      await IOOverrides.runZoned(
        () async {
          final task = await upstream.connectionFactory!(
            Uri.parse('https://catalog.test/media'),
            null,
            null,
          );
          await expectLater(task.socket, throwsA(isA<TlsException>()));
        },
        socketStartConnect:
            (
              dynamic host,
              int port, {
              dynamic sourceAddress,
              int sourcePort = 0,
            }) async {
              attempted.add((host as InternetAddress).address);
              final socket = sockets[attempted.length - 1];
              return ConnectionTask.fromSocket(
                Future<Socket>.value(socket),
                socket.destroy,
              );
            },
      );
    } finally {
      for (final socket in sockets) {
        socket.destroy();
      }
      await subscription.cancel();
      await server.close();
    }

    expect(attempted, ['8.8.8.8', '1.1.1.1']);
  });

  test(
    'cross-origin playlist children do not inherit sticky credentials',
    () async {
      final upstream = _Client([
        _Response(
          200,
          type: 'application/vnd.apple.mpegurl',
          body: '#EXTM3U\nhttps://1.1.1.1/segment.ts\n',
        ),
      ]);
      final result = await fetch(
        upstream,
        'https://8.8.8.8/master.m3u8',
        headers: {'Authorization': 'Bearer private'},
      );
      final segment = Uri.parse(result.body.split('\n')[1]);
      expect(segment.queryParameters['h'], isNull);
      expect(segment.queryParameters['o'], isNull);
    },
  );
}
