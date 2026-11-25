import 'dart:async';

import 'package:animewitcher/core/network/dio_client_provider.dart';
import 'package:animewitcher/core/services/artwork_fallback_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_storage_service.dart';

import 'package:animewitcher/core/storage/storage_service.dart';

const _wait = Duration(seconds: 4);
const _cover = 'https://fixture.invalid/c26-core-cover.png';
const _different = 'https://fixture.invalid/c26-core-different.png';
const _obsolete = 'https://fixture.invalid/c26-core-obsolete.png';

final class _Request {
  _Request(this.options, this.handler);
  final RequestOptions options;
  final RequestInterceptorHandler handler;

  void assertQuery(List<int> ids) {
    final request = options.data as Map;
    expect(options.method, 'POST');
    expect(options.uri.host, 'graphql.anilist.co');
    expect(options.contentType, Headers.jsonContentType);
    expect(request['query'], contains('type: ANIME'));
    expect((request['variables'] as Map)['ids'], ids);
  }

  void answerIds(Map<int, String> covers) {
    handler.resolve(
      Response<Map<String, dynamic>>(
        requestOptions: options,
        statusCode: 200,
        data: {
          'data': {
            'Page': {
              'media': [
                for (final entry in covers.entries)
                  {
                    'idMal': entry.key,
                    'coverImage': {'extraLarge': entry.value},
                  },
              ],
            },
          },
        },
      ),
    );
  }

  void timeout() {
    handler.reject(
      DioException(
        requestOptions: options,
        type: DioExceptionType.receiveTimeout,
      ),
    );
  }

  void noAniZipArt(int id) {
    expect(options.method, 'GET');
    expect(options.uri.host, 'api.ani.zip');
    expect(options.queryParameters['mal_id'], id);
    handler.resolve(
      Response<Map<String, dynamic>>(
        requestOptions: options,
        statusCode: 200,
        data: {'images': const <Object>[]},
      ),
    );
  }
}

final class _DioTransport {
  _DioTransport() {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final record = _Request(options, handler);
          final index = requests.length;
          requests.add(record);
          _readers.remove(index)?.complete(record);
        },
      ),
    );
  }

  final dio = Dio();
  final requests = <_Request>[];
  final _readers = <int, Completer<_Request>>{};

  Future<_Request> nth(int index) {
    if (requests.length > index) return Future.value(requests[index]);
    return _readers
        .putIfAbsent(index, Completer<_Request>.new)
        .future
        .timeout(_wait);
  }

  void close() => dio.close(force: true);
}

final class _Observer extends ProviderObserver {
  int creations = 0;
  int unmounts = 0;
  int disposals = 0;

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    if (context.provider == artworkFallbackServiceProvider) creations++;
  }

  @override
  void didUnmountProvider(ProviderObserverContext context) {
    if (context.provider == artworkFallbackServiceProvider) unmounts++;
  }

  @override
  void didDisposeProvider(ProviderObserverContext context) {
    if (context.provider == artworkFallbackServiceProvider) disposals++;
  }
}

ProviderContainer _container(_DioTransport backend, _Observer observer) =>
    ProviderContainer(
      observers: [observer],
      overrides: [
        storageServiceProvider.overrideWithValue(MemoryStorageService()),
        dioClientProvider.overrideWithValue(backend.dio),
      ],
    );

ArtworkFallbackService _service(ProviderContainer container) =>
    container.read(artworkFallbackServiceProvider);

final class _SwitchTransport extends Notifier<Dio> {
  _SwitchTransport(this.initial);
  final Dio initial;

  @override
  Dio build() => initial;

  void select(Dio next) => state = next;
}

Future<void> _drainCompletion() async {
  // Advance to the next event turn after resolving the fake Dio interception,
  // letting the request/response continuation drain without a timed sleep.
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test(
    'a flushed anime ID shares only its own future and releases its lease',
    () async {
      const id = 196026601;
      const other = 196026602;
      final backend = _DioTransport();
      final observer = _Observer();
      final scope = _container(backend, observer);
      addTearDown(backend.close);
      addTearDown(scope.dispose);

      final service = _service(scope);
      final first = service.posterFor(id);
      expect(service.posterFor(id), same(first), reason: 'already queued');
      final firstRequest = await backend.nth(0);
      firstRequest.assertQuery([id]);
      await scope.pump();
      expect(observer.unmounts, 0);
      expect(_service(scope), same(service));
      expect(
        _service(scope).posterFor(id),
        same(first),
        reason: 'already sent',
      );

      final second = _service(scope).posterFor(other);
      expect(second, isNot(same(first)));
      final secondRequest = await backend.nth(1);
      secondRequest.assertQuery([other]);

      firstRequest.answerIds({id: _cover});
      expect(await first.timeout(_wait), _cover);
      await scope.pump();
      expect(
        observer.unmounts,
        0,
        reason: 'the independent ID still needs its lease',
      );
      secondRequest.answerIds({other: _different});
      expect(await second.timeout(_wait), _different);

      await scope.pump();
      expect(observer.creations, 1);
      expect(observer.unmounts, 1);
      expect(await _service(scope).posterFor(id), _cover);
      await scope.pump();
      expect(
        observer.creations,
        2,
        reason: 'settled hit needs no permanent service lease',
      );
      expect(observer.unmounts, 2);
      expect(backend.requests, hasLength(2));
    },
  );

  test('timeout releases the uncertain result and later answered absence is cached', () async {
    const id = 196026603;
    final backend = _DioTransport();
    final observer = _Observer();
    final scope = _container(backend, observer);
    addTearDown(backend.close);
    addTearDown(scope.dispose);

    final service = _service(scope);
    final failed = service.posterFor(id);
    final primary = await backend.nth(0);
    primary.assertQuery([id]);
    expect(_service(scope).posterFor(id), same(failed));
    primary.timeout();
    final backup = await backend.nth(1);
    expect(backup.options.uri.host, 'api.ani.zip');
    backup.timeout();
    expect(await failed.timeout(_wait), isNull);
    expect(service.hasResolved(id), isFalse);
    await scope.pump();
    expect(observer.unmounts, 1);

    final retryService = _service(scope);
    final retry = retryService.posterFor(id);
    expect(retry, isNot(same(failed)));
    final newPrimary = await backend.nth(2);
    newPrimary.assertQuery([id]);
    newPrimary.answerIds({});
    final newBackup = await backend.nth(3);
    newBackup.noAniZipArt(id);
    expect(await retry.timeout(_wait), isNull);
    expect(
      retryService.hasResolved(id),
      isTrue,
      reason: 'answered miss is retained',
    );
    await scope.pump();
    expect(observer.unmounts, 2);
    expect(await _service(scope).posterFor(id), isNull);
    await scope.pump();
    expect(observer.unmounts, 3);
    expect(backend.requests, hasLength(4));
  });

  test('a second provider container does not share unresolved work', () async {
    const id = 196026604;
    final left = _DioTransport();
    final right = _DioTransport();
    final old = _container(left, _Observer());
    final fresh = _container(right, _Observer());
    addTearDown(left.close);
    addTearDown(right.close);
    addTearDown(fresh.dispose);

    final first = _service(old).posterFor(id);
    final leftRequest = await left.nth(0);
    leftRequest.assertQuery([id]);
    final rightService = _service(fresh);
    final second = rightService.posterFor(id);
    final rightRequest = await right.nth(0);
    rightRequest.assertQuery([id]);
    expect(second, isNot(same(first)));
    old.dispose();
    expect(
      await first.timeout(_wait),
      isNull,
      reason: 'disposed owner settles',
    );

    leftRequest.answerIds({id: _obsolete});
    await _drainCompletion();
    expect(
      rightService.hasResolved(id),
      isFalse,
      reason: 'abandoned result did not publish',
    );
    rightRequest.answerIds({id: _cover});
    expect(await second.timeout(_wait), _cover);
  });

  test(
    'replacing the transport dependency cannot hand off abandoned results',
    () async {
      const id = 196026605;
      final earlier = _DioTransport();
      final current = _DioTransport();
      final selection = NotifierProvider<_SwitchTransport, Dio>(
        () => _SwitchTransport(earlier.dio),
      );
      final observer = _Observer();
      final scope = ProviderContainer(
        observers: [observer],
        overrides: [
          storageServiceProvider.overrideWithValue(MemoryStorageService()),
          dioClientProvider.overrideWith((ref) => ref.watch(selection)),
        ],
      );
      addTearDown(earlier.close);
      addTearDown(current.close);
      addTearDown(scope.dispose);

      final previous = _service(scope);
      final oldResult = previous.posterFor(id);
      final oldRequest = await earlier.nth(0);
      oldRequest.assertQuery([id]);
      scope.read(selection.notifier).select(current.dio);
      final replacement = _service(scope);
      expect(replacement, isNot(same(previous)));
      expect(await oldResult.timeout(_wait), isNull);
      expect(
        await previous.posterFor(id),
        isNull,
        reason: 'old generation cannot admit work',
      );

      final latest = replacement.posterFor(id);
      final newRequest = await current.nth(0);
      newRequest.assertQuery([id]);
      oldRequest.answerIds({id: _obsolete});
      await _drainCompletion();
      expect(replacement.hasResolved(id), isFalse);
      newRequest.answerIds({id: _cover});
      expect(await latest.timeout(_wait), _cover);
      await scope.pump();
      expect(observer.disposals, greaterThanOrEqualTo(2));
      expect(observer.unmounts, 1);
      expect(earlier.requests, hasLength(1));
      expect(current.requests, hasLength(1));
    },
  );
}
