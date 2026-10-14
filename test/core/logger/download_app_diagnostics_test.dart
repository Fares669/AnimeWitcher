import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/logger/app_diagnostics.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../services/download_v2/download_v2_test_support.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

class _Gateway extends Fake implements BackgroundDownloaderGateway {
  final ready = Completer<void>();
  @override
  Future<void> initialize() => ready.future;
  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'app log identifies blocked download startup without changing its failure',
    () async {
      final root = await Directory.systemTemp.createTemp('app-download-log-');
      final previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      final gateway = _Gateway();
      final manager = DownloadManagerV2(
        store: InMemoryLogicalDownloadStoreV2(),
        gateway: gateway,
        sourceResolver: StaticSourceResolverV2(),
      );
      try {
        await appDiagnostics.setEnabled(true);
        final start = manager.initialize();
        final expectation = expectLater(start, throwsA(isA<StateError>()));
        await appDiagnostics.flush();
        final log = await appDiagnostics.export();
        final events = (await log.readAsLines())
            .where((line) => line.trim().isNotEmpty)
            .map((line) => jsonDecode(line) as Map<String, dynamic>)
            .where((event) => event['event'] == 'download.init')
            .toList();
        expect(
          events.any(
            (event) =>
                event['phase'] == 'begin' &&
                event['operation'] == 'gatewayInitialize',
          ),
          isTrue,
        );
        expect(events.any((event) => event['phase'] == 'end'), isFalse);
        gateway.ready.completeError(
          StateError('https://private.example/?token=SUPER_SECRET'),
        );
        await expectation;
        await appDiagnostics.flush();
        final after = await (await appDiagnostics.export()).readAsString();
        expect(after, isNot(contains('SUPER_SECRET')));
        expect(after, isNot(contains('private.example')));
        expect(after, contains('StateError'));
      } finally {
        await manager.dispose();
        await appDiagnostics.setEnabled(false);
        await appDiagnostics.flush();
        PathProviderPlatform.instance = previous;
        await root.delete(recursive: true);
      }
    },
  );
}
