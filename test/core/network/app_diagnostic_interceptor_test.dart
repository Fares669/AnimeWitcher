import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:animewitcher/core/logger/app_diagnostics.dart';
import 'package:animewitcher/core/network/app_diagnostic_interceptor.dart';
import 'package:animewitcher/core/network/stale_connection_retry.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions, int) respond;
  int calls = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => respond(options, ++calls);
  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory directory;
  late AppDiagnostics diagnostics;
  late Dio dio;

  Future<List<Map<String, dynamic>>> events() async {
    await diagnostics.flush();
    final rows = <Map<String, dynamic>>[];
    for (final file in await diagnostics.listFiles()) {
      rows.addAll(
        (await file.readAsLines()).map(
          (line) => jsonDecode(line) as Map<String, dynamic>,
        ),
      );
    }
    return rows
        .where((row) => (row['event'] as String).startsWith('network_'))
        .toList();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('network-log-test-');
    diagnostics = AppDiagnostics(directoryProvider: () async => directory);
    await diagnostics.setEnabled(true);
    dio = Dio()
      ..interceptors.add(AppDiagnosticInterceptor(diagnostics: diagnostics));
  });
  tearDown(() async {
    dio.close(force: true);
    await diagnostics.setEnabled(false);
    await diagnostics.flush();
    await directory.delete(recursive: true);
  });

  test(
    'success records timing and correlation without any request data',
    () async {
      dio.httpClientAdapter = _Adapter((options, _) async {
        expect(options.headers['Authorization'], 'Bearer secret-header');
        expect(options.data, {'password': 'secret-body'});
        return ResponseBody.fromString('secret-response', 200);
      });
      final response = await dio.post<String>(
        'https://secret-host.test/private/secret-path?token=secret-query',
        data: {'password': 'secret-body'},
        options: Options(headers: {'Authorization': 'Bearer secret-header'}),
      );
      expect(response.data, 'secret-response');
      final rows = await events();
      expect(rows.map((row) => row['event']), [
        'network_start',
        'network_finish',
      ]);
      final start = rows.first;
      final finish = rows.last;
      expect(start['method'], 'POST');
      expect(finish['status'], 200);
      expect(finish['request_id'], start['request_id']);
      expect(finish['duration_ms'], isNonNegative);
      expect(jsonEncode(rows), isNot(contains('secret')));
    },
  );

  test('HTTP failure leaves original exception and status intact', () async {
    dio.httpClientAdapter = _Adapter(
      (_, _) async => ResponseBody.fromString('secret-response', 503),
    );
    DioException? failure;
    try {
      await dio.get<dynamic>('https://secret-host.test/secret-path');
    } on DioException catch (error) {
      failure = error;
    }
    expect(failure?.type, DioExceptionType.badResponse);
    expect(failure?.response?.statusCode, 503);
    final rows = await events();
    expect(rows.map((row) => row['event']), ['network_start', 'network_error']);
    expect(rows.last, containsPair('status', 503));
    expect(rows.last, containsPair('error_type', 'badResponse'));
    expect(jsonEncode(rows), isNot(contains('secret')));
  });

  test('stale retry keeps request id and logs each attempt once', () async {
    final adapter = _Adapter((_, attempt) async {
      if (attempt == 1) throw const SocketException('secret hostname');
      return ResponseBody.fromString('ok', 200);
    });
    dio.httpClientAdapter = adapter;
    dio.interceptors.add(StaleConnectionRetryInterceptor(dio));
    final response = await dio.get<String>(
      'https://secret-host.test/secret-path',
    );
    expect(response.data, 'ok');
    expect(adapter.calls, 2);
    final rows = await events();
    expect(rows.map((row) => row['event']), [
      'network_start',
      'network_error',
      'network_start',
      'network_finish',
    ]);
    expect(rows.map((row) => row['request_id']).toSet(), hasLength(1));
    expect(rows.map((row) => row['attempt']), [1, 1, 2, 2]);
    expect(jsonEncode(rows), isNot(contains('secret')));
  });

  test(
    'cancellation is logged and retains Dio cancellation behavior',
    () async {
      final cancel = CancelToken();
      dio.httpClientAdapter = _Adapter((options, _) async {
        cancel.cancel('secret cancellation reason');
        await cancel.whenCancel;
        throw cancel.cancelError!;
      });
      await expectLater(
        dio.get<dynamic>(
          'https://secret-host.test/secret-path',
          cancelToken: cancel,
        ),
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      final rows = await events();
      expect(rows.map((row) => row['event']), [
        'network_start',
        'network_error',
      ]);
      expect(rows.last, containsPair('error_type', 'cancel'));
      expect(jsonEncode(rows), isNot(contains('secret')));
    },
  );
}
