import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/utils/artwork_host_fallback.dart';
import 'package:animewitcher/main.dart';
import 'package:animewitcher/shared/widgets/loading_indicator.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'support/memory_storage_service.dart';

const _mal = 'https://cdn.myanimelist.net/images/poster.jpg';
const _aniList = 'https://s4.anilist.co/poster.jpg';
const _step = Duration(milliseconds: 50);

class _Storage extends MemoryStorageService {
  _Storage({
    this.delay = Duration.zero,
    this.initDelay = Duration.zero,
    this.probedAt,
    this.unreachable = false,
    this.failWrite = false,
  });

  final Duration delay;
  final Duration initDelay;
  DateTime? probedAt;
  bool unreachable;
  final bool failWrite;
  int writesStarted = 0;
  int writesFinished = 0;

  @override
  Future<void> init() async {
    if (initDelay != Duration.zero) await Future<void>.delayed(initDelay);
  }

  @override
  DateTime? malArtworkProbedAt() => probedAt;

  @override
  bool isMalArtworkUnreachable() => unreachable;

  @override
  Future<void> setMalArtworkUnreachable(bool value) async {
    writesStarted++;
    if (delay != Duration.zero) await Future<void>.delayed(delay);
    if (failWrite) throw const FileSystemException('test write failed');
    unreachable = value;
    probedAt = DateTime.now();
    writesFinished++;
  }
}

class _Probe {
  _Probe({
    this.dns = Duration.zero,
    this.open = Duration.zero,
    this.headers = Duration.zero,
    this.sinkhole = false,
    this.failHeaders = false,
    this.stalledBody = false,
  });

  final Duration dns;
  final Duration open;
  final Duration headers;
  final bool sinkhole;
  final bool failHeaders;
  final bool stalledBody;
  int lookupCalls = 0;
  int clients = 0;
  int requests = 0;
  int headerWaits = 0;
  int forcedCloses = 0;
  int drains = 0;

  Future<bool?> call({required Duration timeout}) => probeArtworkHost(
    timeout: timeout,
    lookup: (host) async {
      expect(host, 'cdn.myanimelist.net');
      lookupCalls++;
      if (dns != Duration.zero) await Future<void>.delayed(dns);
      return [InternetAddress(sinkhole ? '0.0.0.0' : '192.0.2.1')];
    },
    createClient: () {
      clients++;
      return _Client(this);
    },
  );
}

class _Client implements HttpClient {
  _Client(this.probe);
  final _Probe probe;

  @override
  set connectionTimeout(Duration? value) {}

  @override
  Future<HttpClientRequest> headUrl(Uri url) async {
    expect(url.host, 'cdn.myanimelist.net');
    probe.requests++;
    if (probe.open != Duration.zero) await Future<void>.delayed(probe.open);
    return _Request(probe);
  }

  @override
  void close({bool force = false}) {
    if (force) probe.forcedCloses++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.probe);
  final _Probe probe;

  @override
  Future<HttpClientResponse> close() async {
    probe.headerWaits++;
    if (probe.headers != Duration.zero) {
      await Future<void>.delayed(probe.headers);
    }
    if (probe.failHeaders) throw const SocketException('test host unreachable');
    return _Response(probe);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.probe);
  final _Probe probe;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    probe.drains++;
    final body = probe.stalledBody
        ? Stream<List<int>>.fromFuture(Completer<List<int>>().future)
        : const Stream<List<int>>.empty();
    return body.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(_Storage storage, _Probe probe, {Widget? application}) =>
    AppRoot.test(
      storage,
      probe.call,
      // The production AppRoot controls when this subtree mounts. Suppress
      // unrelated device/plugins/Dio work and resolve the first candidate the
      // same way as the catalog's artwork picker.
      application ??
          Builder(
            builder: (_) => Directionality(
              textDirection: TextDirection.ltr,
              child: Text(preferReachableArtwork(const [_mal, _aniList]).first),
            ),
          ),
    );

Future<int> _firstArtwork(WidgetTester tester, [String? url]) async {
  for (var elapsed = 0; elapsed <= 5000; elapsed += _step.inMilliseconds) {
    if (url == null
        ? find.text(_mal).evaluate().isNotEmpty ||
              find.text(_aniList).evaluate().isNotEmpty
        : find.text(url).evaluate().isNotEmpty) {
      return elapsed;
    }
    await tester.pump(_step);
  }
  fail('First artwork candidate was not visible within 5 seconds.');
}

void main() {
  tearDown(() {
    seedMalArtworkReachability(false);
    applyArtworkFallbackEnabled(false);
  });

  testWidgets('all first-run probe stages share one 1.5 s shell budget', (
    tester,
  ) async {
    final storage = _Storage(delay: const Duration(milliseconds: 1200));
    final probe = _Probe(
      dns: const Duration(milliseconds: 800),
      open: const Duration(milliseconds: 800),
      headers: const Duration(milliseconds: 800),
    );
    await tester.pumpWidget(_app(storage, probe));
    expect(find.byType(AppLoadingIndicator), findsOneWidget);

    final elapsed = await _firstArtwork(tester);
    // A/B audit: simulated elapsed startup time, not device or wall time.
    printOnFailure('Controlled first artwork candidate at ${elapsed}ms');
    expect(elapsed, 1500);
    expect(find.text(_aniList), findsOneWidget);
    expect(probe.forcedCloses, 1);
    expect(storage.writesStarted, 0);
    expect(malArtworkUnreachable.value, isTrue);
    await tester.pump(const Duration(seconds: 3));
    expect(probe.headerWaits, 0, reason: 'late connect must not send HEAD');
    expect(probe.drains, 0);
    expect(storage.probedAt, isNull);
  });

  testWidgets('first artwork does not wait for HEAD drain or a slow write', (
    tester,
  ) async {
    final storage = _Storage(delay: const Duration(milliseconds: 1200));
    final probe = _Probe(
      dns: _step,
      open: _step,
      headers: _step,
      stalledBody: true,
    );
    await tester.pumpWidget(_app(storage, probe));

    expect(await _firstArtwork(tester, _mal), 150);
    expect(probe.forcedCloses, 1);
    expect(probe.headerWaits, 1);
    expect(probe.drains, 0);
    expect(storage.writesStarted, 1);
    expect(storage.writesFinished, 0);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(storage.writesFinished, 1);
    expect(storage.probedAt, isNotNull);
    expect(storage.unreachable, isFalse);
  });

  testWidgets('a sinkhole seeds AniList before the first shell paint', (
    tester,
  ) async {
    final storage = _Storage(
      delay: const Duration(milliseconds: 1200),
      failWrite: true,
    );
    final probe = _Probe(dns: _step, sinkhole: true);
    await tester.pumpWidget(_app(storage, probe));

    expect(await _firstArtwork(tester, _aniList), 50);
    expect(probe.lookupCalls, 1);
    expect(probe.clients, 0);
    expect(storage.writesStarted, 1);
    // A storage error cannot undo this session's result or break startup.
    await tester.pump(const Duration(milliseconds: 1200));
    expect(tester.takeException(), isNull);
    expect(find.text(_aniList), findsOneWidget);
    expect(malArtworkUnreachable.value, isTrue);
  });

  testWidgets('a slow DNS answer never opens a client after timeout', (
    tester,
  ) async {
    // A previous split write may have set reachability without a timestamp.
    final storage = _Storage(unreachable: true);
    final probe = _Probe(dns: const Duration(seconds: 2));
    await tester.pumpWidget(_app(storage, probe));

    expect(await _firstArtwork(tester, _aniList), 1500);
    await tester.pump(const Duration(milliseconds: 500));
    expect(probe.lookupCalls, 1);
    expect(probe.clients, 0);
    expect(storage.writesStarted, 0);
    expect(malArtworkUnreachable.value, isTrue);
  });

  testWidgets('a late negative header result cannot update or persist', (
    tester,
  ) async {
    final storage = _Storage();
    final probe = _Probe(
      dns: _step,
      open: _step,
      headers: const Duration(seconds: 2),
      failHeaders: true,
    );
    await tester.pumpWidget(_app(storage, probe));
    expect(await _firstArtwork(tester, _aniList), 1500);
    expect(probe.headerWaits, 1);
    expect(probe.forcedCloses, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(storage.writesStarted, 0);
    expect(malArtworkUnreachable.value, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'blackholed HEAD gives the native Home rail a temporary alternate',
    (tester) async {
      final storage = _Storage();
      final probe = _Probe(open: const Duration(seconds: 4));
      final dio = Dio();
      addTearDown(() => dio.close(force: true));
      final provider = AnimeWitcherNativeProvider(
        dio,
        SettingsRepository(storage),
      );
      const title = 'Art startup fixture';
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            final path = request.uri.path;
            final data = switch (path) {
              String() when path.endsWith('/Settings/constants') => {
                'fields': {
                  'search_settings': {
                    'mapValue': {
                      'fields': {
                        'app_id_v3': {'stringValue': 'ARTFIXTURE'},
                        'api_key': {'stringValue': 'fixture-key'},
                        'is_search_active': {'booleanValue': true},
                      },
                    },
                  },
                },
              },
              String() when path.endsWith('/Settings/home_sections') => {
                'fields': {
                  'sections': {
                    'arrayValue': {
                      'values': [
                        {
                          'mapValue': {
                            'fields': {
                              'title': {'stringValue': title},
                              'type': {'stringValue': 'list'},
                              'index_name': {'stringValue': 'series'},
                              'hits_per_page': {'integerValue': '10'},
                            },
                          },
                        },
                      ],
                    },
                  },
                },
              },
              '/1/indexes/series/query' => {
                'hits': [
                  {
                    'objectID': 'startup-art-fixture',
                    'name': 'Startup poster',
                    'poster': {'large': _mal, 'medium': _mal},
                    'poster_url_aniList': _aniList,
                  },
                ],
                'nbPages': 1,
              },
              _ => throw StateError('Unexpected catalogue path: $path'),
            };
            handler.resolve(
              Response<Object?>(
                requestOptions: request,
                statusCode: 200,
                data: data,
              ),
            );
          },
        ),
      );
      await tester.pumpWidget(
        _app(
          storage,
          probe,
          application: Directionality(
            textDirection: TextDirection.ltr,
            child: Builder(
              builder: (_) => FutureBuilder(
                future: provider.getHome(),
                builder: (_, snapshot) => Text(
                  snapshot.data?[title]?.single.posterUrl ??
                      (snapshot.error?.toString() ?? 'loading catalog'),
                ),
              ),
            ),
          ),
        ),
      );
      await _firstArtwork(tester, _aniList);
      expect(probe.forcedCloses, 1);
      expect(storage.probedAt, isNull);
      expect(storage.writesStarted, 0);
      expect(artworkFallbackEnabled.value, isFalse);
      expect(find.text(_mal), findsNothing);

      // A restart before the old request completes reseeds from the storage
      // default. The new, immediately reachable probe restores the MAL choice.
      await tester.pumpWidget(const SizedBox.shrink());
      final reachable = _Probe();
      await tester.pumpWidget(_app(storage, reachable));
      await _firstArtwork(tester, _mal);
      expect(storage.writesFinished, 1);
      expect(storage.unreachable, isFalse);
      await tester.pump(const Duration(seconds: 4));
      expect(probe.headerWaits, 0);
      expect(storage.writesStarted, 1);
      expect(malArtworkUnreachable.value, isFalse);
    },
  );

  testWidgets('cached reachable results survive an inconclusive refresh', (
    tester,
  ) async {
    final storage = _Storage(
      probedAt: DateTime.now().subtract(const Duration(hours: 7)),
    );
    final probe = _Probe(headers: const Duration(seconds: 4));
    await tester.pumpWidget(_app(storage, probe));
    await tester.pump();
    expect(find.text(_mal), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(probe.forcedCloses, 1);
    expect(storage.writesStarted, 0);
    expect(malArtworkUnreachable.value, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(storage.writesStarted, 0);
  });

  testWidgets('a known block seeds launch while background refresh runs', (
    tester,
  ) async {
    final storage = _Storage(probedAt: DateTime.now(), unreachable: true);
    final probe = _Probe(headers: const Duration(milliseconds: 500));
    await tester.pumpWidget(_app(storage, probe));
    // One frame allows the asynchronous storage initialization. There is no
    // advance of the probe's fake clock before the first shell paint.
    await tester.pump();
    expect(find.text(_aniList), findsOneWidget);
    expect(probe.lookupCalls, 1);
    expect(probe.headerWaits, 1);
    expect(storage.writesStarted, 0);
    await tester.pump(const Duration(milliseconds: 500));
    expect(probe.forcedCloses, 1);
    expect(storage.writesFinished, 1);
    expect(storage.unreachable, isFalse);
  });

  testWidgets('a recent known reachable result makes no network probe', (
    tester,
  ) async {
    final storage = _Storage(probedAt: DateTime.now());
    final probe = _Probe();
    await tester.pumpWidget(_app(storage, probe));
    await tester.pump();
    expect(find.text(_mal), findsOneWidget);
    expect(probe.lookupCalls, 0);
    expect(storage.writesStarted, 0);
  });

  testWidgets('a disposed startup may not seed or write after a late answer', (
    tester,
  ) async {
    final oldStorage = _Storage();
    final oldProbe = _Probe(
      headers: const Duration(milliseconds: 500),
      failHeaders: true,
    );
    await tester.pumpWidget(_app(oldStorage, oldProbe));
    await tester.pump(_step);
    expect(oldProbe.headerWaits, 1);
    await tester.pumpWidget(const SizedBox.shrink());

    final newStorage = _Storage(probedAt: DateTime.now());
    final newProbe = _Probe();
    await tester.pumpWidget(_app(newStorage, newProbe));
    await tester.pump();
    expect(find.text(_mal), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect(oldProbe.forcedCloses, 1);
    expect(oldStorage.writesStarted, 0);
    expect(newStorage.writesStarted, 0);
    expect(malArtworkUnreachable.value, isFalse);
  });

  testWidgets('disposed storage initialization cannot replace a new seed', (
    tester,
  ) async {
    final storage = _Storage(
      initDelay: const Duration(milliseconds: 500),
      unreachable: true,
    );
    final probe = _Probe();
    await tester.pumpWidget(_app(storage, probe));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_app(_Storage(probedAt: DateTime.now()), _Probe()));
    await tester.pump();
    expect(find.text(_mal), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect(probe.lookupCalls, 0);
    expect(storage.writesStarted, 0);
    expect(malArtworkUnreachable.value, isFalse);
  });

  test(
    'reachability and its timestamp become visible together in Hive',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'aw-artwork-reachability-',
      );
      Hive.init(dir.path);
      addTearDown(() async {
        await Hive.close();
        await dir.delete(recursive: true);
      });
      const name = 'artwork_reachability';
      final box = await Hive.openBox<dynamic>(name);
      final storage = StorageService()..debugBindSettingsBox(box);
      expect(storage.malArtworkProbedAt(), isNull);
      final first = storage.setMalArtworkUnreachable(true);
      expect(storage.isMalArtworkUnreachable(), isTrue);
      expect(storage.malArtworkProbedAt(), isNotNull);
      final newest = storage.setMalArtworkUnreachable(false);
      await Future.wait([first, newest]);
      await box.close();
      final reopened = StorageService()
        ..debugBindSettingsBox(await Hive.openBox<dynamic>(name));
      expect(reopened.isMalArtworkUnreachable(), isFalse);
      expect(reopened.malArtworkProbedAt(), isNotNull);
    },
  );
}
