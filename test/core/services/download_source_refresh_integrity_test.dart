import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:animewitcher/core/services/download_range_transfer.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'source identity probe accepts matching prefix and exposes validator',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'aw-source-proof-',
      );
      final file = File('${directory.path}/part');
      await file.writeAsBytes(<int>[0, 1, 2, 3]);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final dio = Dio();
      final url = 'http://${server.address.host}:${server.port}/episode';
      unawaited(() async {
        await for (final request in server) {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 20-23/100',
          );
          request.response.headers.set(HttpHeaders.etagHeader, '"same-v2"');
          request.response.add(<int>[0, 1, 2, 3]);
          await request.response.close();
        }
      }());

      try {
        final runner = DownloadRangeTransfer(dio);
        final result = await runner.verifyExistingPrefix(
          id: 'part-1',
          url: url,
          headers: const {'Range': 'bytes=20-39'},
          file: file,
          written: 4,
        );
        expect(result.matches, isTrue);
        expect(result.validator, '"same-v2"');
      } finally {
        dio.close(force: true);
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );

  test('source identity probe rejects changed bytes before append', () async {
    final directory = await Directory.systemTemp.createTemp('aw-source-proof-');
    final file = File('${directory.path}/part');
    await file.writeAsBytes(<int>[0, 1, 2, 3]);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final dio = Dio();
    final url = 'http://${server.address.host}:${server.port}/episode';
    unawaited(() async {
      await for (final request in server) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 20-23/100',
        );
        request.response.add(<int>[9, 9, 9, 9]);
        await request.response.close();
      }
    }());

    try {
      final runner = DownloadRangeTransfer(dio);
      final result = await runner.verifyExistingPrefix(
        id: 'part-1',
        url: url,
        headers: const {'Range': 'bytes=20-39'},
        file: file,
        written: 4,
      );
      expect(result.matches, isFalse);
      expect(await file.readAsBytes(), <int>[0, 1, 2, 3]);
    } finally {
      dio.close(force: true);
      await server.close(force: true);
      await directory.delete(recursive: true);
    }
  });

  test(
    'refreshed multipart child metadata explicitly fences old resumeData',
    () {
      final task = DownloadTask(
        url: 'https://cdn.test/new',
        group: kPersistentDownloadChunkGroup,
        metaData: jsonEncode(<String, Object>{
          'parentTaskId': 'parent',
          'sourceValidationRequired': true,
        }),
      );
      expect(downloadInternalParentTaskId(task), 'parent');
      expect(downloadInternalSourceValidationRequired(task), isTrue);
    },
  );

  test(
    'DownloadService delegates logical merge policy to DownloadJobStore',
    () {
      final service = File('lib/core/services/download_service.dart')
          .readAsStringSync();
      final start = service.indexOf('Future<bool> _checkpointLogicalJob(');
      final end = service.indexOf(
        'Future<void> _recoverPersistedDownloads',
        start,
      );
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final section = service.substring(start, end);
      expect(section, contains('_jobStore.checkpoint('));
      expect(section, isNot(contains('DownloadJobRecord(')));

      final parallel = File(
        'lib/core/services/persistent_parallel_download.dart',
      ).readAsStringSync();
      expect(parallel, contains('verifyPartSource'));
      expect(parallel, contains('sourceValidationRequired'));
    },
  );
}
