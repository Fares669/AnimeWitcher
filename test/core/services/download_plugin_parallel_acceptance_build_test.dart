import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('acceptance build stays opt-in and is wired into DownloadService', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();

    expect(
      source,
      contains("'ANIMEWITCHER_PLUGIN_PARALLEL_ACCEPTANCE'"),
      reason: 'device acceptance needs an explicit compile-time-only switch',
    );
    expect(
      source,
      contains('defaultValue: false'),
      reason: 'ordinary production and preview builds must remain fail-closed',
    );
    expect(
      source,
      contains('pluginParallelAcceptedForBuild('),
      reason: 'DownloadService must consult the build gate, not bypass it',
    );
    expect(
      source,
      contains(
        'acceptanceBuildOverride: _pluginParallelAcceptanceBuildOverride',
      ),
      reason: 'only the compile-time acceptance artifact may override the gate',
    );
  });

  test('preview workflow exposes a fail-closed acceptance build input', () {
    final workflow = File('.github/workflows/preview.yml').readAsStringSync();

    expect(workflow, contains('plugin_parallel_acceptance:'));
    expect(
      workflow,
      contains("description: 'Enable plugin-parallel device acceptance mode'"),
    );
    expect(
      workflow,
      contains(
        r'"ANIMEWITCHER_PLUGIN_PARALLEL_ACCEPTANCE": ${{ github.event.inputs.plugin_parallel_acceptance }}',
      ),
      reason: 'preview artifacts must receive the opt-in compile-time define',
    );
  });
}
