import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final unsafe in [false, true]) {
    test(
      'production logger uses ${unsafe ? 'sanitized' : 'installed'} build identity',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'aw-v2-installed-build-',
        );
        final previousPaths = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _Paths(directory.path);
        addTearDown(() async {
          PathProviderPlatform.instance = previousPaths;
          await directory.delete(recursive: true);
        });
        PackageInfo.setMockInitialValues(
          appName: 'private app label',
          packageName: 'private.package.name',
          version: unsafe ? 'https://private.invalid/?token=secret' : '1.6.3',
          buildNumber: unsafe ? 'Bearer secret' : '5',
          buildSignature: 'secret-signature',
        );
        final container = ProviderContainer(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(_Settings()),
          ],
        );
        addTearDown(container.dispose);
        final diagnostics = container.read(downloadDiagnosticsFileV2Provider);
        diagnostics.recordTransport('parallel.heartbeat', {
          'taskId': 'episode',
        });
        await diagnostics.flush();

        final text = await (await diagnostics.listFiles()).single
            .readAsString();
        final row = jsonDecode(text) as Map<String, dynamic>;
        expect(row['appVersion'], unsafe ? 'unknown' : '1.6.3');
        expect(row['appBuildNumber'], unsafe ? 'unknown' : '5');
        expect(row['buildFingerprint'], unsafe ? 'unknown+unknown' : '1.6.3+5');
        expect(row['schemaVersion'], 1);
        expect(text, isNot(contains('private')));
        expect(text, isNot(contains('secret')));
        expect(row.keys, isNot(contains('commit')));
      },
    );
  }
}

final class _Settings extends SettingsRepository {
  _Settings() : super(StorageService());

  @override
  bool getDownloadDiagnosticLog() => true;
}

final class _Paths extends PathProviderPlatform {
  _Paths(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}
