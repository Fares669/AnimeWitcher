import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('acceptance override is compile-time only and production stays closed', () {
    final source = File('lib/core/services/download_transport_policy.dart')
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
      reason: 'platform routing must pass through the acceptance build gate',
    );
    expect(
      source,
      contains(
        'acceptanceBuildOverride: _pluginParallelAcceptanceBuildOverride',
      ),
      reason: 'only the compile-time acceptance artifact may override the gate',
    );
  });

  test('iOS acceptance workflow explicitly opts into plugin parallel mode', () {
    final workflow = File(
      '.github/workflows/verify-plugin-parallel-acceptance.yml',
    ).readAsStringSync();

    expect(workflow, contains('Build Plugin Parallel Acceptance'));
    expect(
      workflow,
      contains(
        '--dart-define=ANIMEWITCHER_PLUGIN_PARALLEL_ACCEPTANCE=true',
      ),
      reason: 'the acceptance IPA must opt in explicitly at compile time',
    );
    expect(workflow, contains('flutter build ios --release --no-codesign'));
    expect(workflow, contains('animewitcher-ios-plugin-parallel-acceptance.ipa'));
  });
}
