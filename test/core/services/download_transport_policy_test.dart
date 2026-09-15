import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:animewitcher/core/services/download_transport_policy.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('selectDownloadExecutionBackend', () {
    test('single connection always uses plugin single transport', () {
      expect(
        selectDownloadExecutionBackend(
          connections: 1,
          pluginParallelAccepted: false,
          legacySessionExists: false,
        ),
        DownloadExecutionBackend.pluginSingle,
      );
    });

    test('unsupported multipart stays on legacy executor', () {
      expect(
        selectDownloadExecutionBackend(
          connections: 8,
          pluginParallelAccepted: false,
          legacySessionExists: false,
        ),
        DownloadExecutionBackend.legacyParallel,
      );
    });

    test('accepted new multipart uses plugin parallel transport', () {
      expect(
        selectDownloadExecutionBackend(
          connections: 8,
          pluginParallelAccepted: true,
          legacySessionExists: false,
        ),
        DownloadExecutionBackend.pluginParallel,
      );
    });

    test('existing legacy multipart never changes executor mid-session', () {
      expect(
        selectDownloadExecutionBackend(
          connections: 8,
          pluginParallelAccepted: true,
          legacySessionExists: true,
        ),
        DownloadExecutionBackend.legacyParallel,
      );
    });
  });

  group('buildPluginTransportTask', () {
    late DownloadTask template;

    setUp(() {
      template = DownloadTask(
        taskId: 'episode-42',
        url: 'https://cdn.example.test/episode-42.mp4',
        urlQueryParameters: const <String, String>{'token': 'signed-token'},
        filename: 'episode-42.mp4',
        directory: 'downloads/series',
        baseDirectory: BaseDirectory.applicationSupport,
        headers: const <String, String>{
          'Referer': 'https://anime.example.test',
          'X-Source': 'primary',
        },
        httpRequestMethod: 'GET',
        group: 'anime-downloads',
        updates: Updates.statusAndProgress,
        requiresWiFi: true,
        retries: 4,
        allowPause: true,
        priority: 3,
        metaData: '{"episodeId":"42"}',
        displayName: 'Episode 42',
        creationTime: DateTime.utc(2026, 9, 15, 12, 30),
        transferHints: const <TransferHint>{TransferHint.largeFile},
        stallTimeout: const Duration(seconds: 45),
      );
    });

    test('single connection keeps the original DownloadTask', () {
      final task = buildPluginTransportTask(template: template, connections: 1);

      expect(task, same(template));
      expect(task, isNot(isA<ParallelDownloadTask>()));
    });

    test('parallel task preserves the transferable task contract', () {
      final task = buildPluginTransportTask(template: template, connections: 8);

      expect(task, isA<ParallelDownloadTask>());
      final parallel = task as ParallelDownloadTask;
      expect(parallel.chunks, 8);
      expect(parallel.taskId, template.taskId);
      expect(parallel.url, template.url);
      expect(parallel.url, contains('token=signed-token'));
      expect(parallel.filename, template.filename);
      expect(parallel.directory, template.directory);
      expect(parallel.baseDirectory, template.baseDirectory);
      expect(parallel.headers, template.headers);
      expect(parallel.httpRequestMethod, template.httpRequestMethod);
      expect(parallel.group, template.group);
      expect(parallel.updates, template.updates);
      expect(parallel.requiresWiFi, template.requiresWiFi);
      expect(parallel.retries, template.retries);
      expect(parallel.allowPause, template.allowPause);
      expect(parallel.priority, template.priority);
      expect(parallel.metaData, template.metaData);
      expect(parallel.displayName, template.displayName);
      expect(parallel.creationTime, template.creationTime);
      expect(parallel.options, template.options);
      expect(parallel.transferHints, template.transferHints);
      expect(parallel.notificationConfig, template.notificationConfig);
      expect(parallel.stallTimeout, template.stallTimeout);
    });

    test('parallel chunk count is capped at the supported maximum', () {
      final task = buildPluginTransportTask(
        template: template,
        connections: kDownloadPartsMax + 50,
      );

      expect(task, isA<ParallelDownloadTask>());
      expect((task as ParallelDownloadTask).chunks, kDownloadPartsMax);
    });
  });
}
