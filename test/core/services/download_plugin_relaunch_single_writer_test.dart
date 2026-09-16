import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parallel resume requires a rehydrated parent before Transfer.resume', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final methodStart = source.indexOf('Future<bool> _resumeDownloadTask(');
    final methodEnd = source.indexOf(
      'Future<bool> _resumeUsingPartialFile(',
      methodStart,
    );
    expect(methodStart, greaterThanOrEqualTo(0));
    expect(methodEnd, greaterThan(methodStart));
    final method = source.substring(methodStart, methodEnd);
    final parallelStart = method.indexOf('if (task is ParallelDownloadTask) {');
    final ordinaryStart = method.indexOf(
      '// Only a validated source replacement may cross the custom Range seam.',
      parallelStart,
    );
    expect(parallelStart, greaterThanOrEqualTo(0));
    expect(ordinaryStart, greaterThan(parallelStart));
    final body = method.substring(parallelStart, ordinaryStart);

    expect(body, contains('if (pluginParentKnown) {'));
    expect(body, contains('await _nativeTransport.resume(task)'));
    expect(body, contains('if (pluginChunkEvidence) {'));
    expect(
      body,
      contains("'reason': 'parentProjectionMissing'"),
      reason: 'surviving plugin chunks without a parent must fail closed',
    );

    final parentBranch = body.indexOf('if (pluginParentKnown) {');
    final chunkOnlyBranch = body.indexOf('if (pluginChunkEvidence) {');
    expect(parentBranch, greaterThanOrEqualTo(0));
    expect(chunkOnlyBranch, greaterThan(parentBranch));
    final chunkOnlyBody = body.substring(chunkOnlyBranch);
    expect(
      chunkOnlyBody,
      isNot(contains('await _nativeTransport.resume(task)')),
      reason:
          'resume must not getOrStart a replacement parent from child-only evidence',
    );
  });

  test('startup quarantines legacy parents before plugin killed-task reschedule', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final startHelper = source.indexOf(
      'Future<void> _startPluginExecutor() async {',
    );
    final startHelperEnd = source.indexOf(
      '/// Test hook that replaces [FileDownloader.configure]',
      startHelper,
    );
    expect(startHelper, greaterThanOrEqualTo(0));
    expect(startHelperEnd, greaterThan(startHelper));
    final helper = source.substring(startHelper, startHelperEnd);

    final quarantine = helper.indexOf(
      '_quarantineLegacyParallelParentsBeforePluginStart()',
    );
    final pluginStart = helper.indexOf('FileDownloader().start(');
    final cancelRogue = helper.indexOf('cancelTasksWithIds(');
    final reschedule = helper.indexOf(
      'await FileDownloader().rescheduleKilledTasks()',
    );
    final rehydrate = helper.indexOf('_nativeTransport.rehydrate(');
    final forgetLegacy = helper.indexOf('_nativeTransport.forget(parentId)');
    final restore = helper.indexOf(
      '_restoreLegacyParallelParentsAfterPluginStart(',
    );

    expect(
      quarantine,
      greaterThanOrEqualTo(0),
      reason:
          'legacy ParallelDownloadTask rows must be identified before background_downloader sees killed work',
    );
    expect(pluginStart, greaterThan(quarantine));
    expect(
      helper,
      contains('doRescheduleKilledTasks: false'),
      reason:
          'FileDownloader.start schedules killed-task recovery on a delayed Timer; startup needs synchronous reconciliation while legacy rows are quarantined',
    );
    expect(cancelRogue, greaterThan(pluginStart));
    expect(reschedule, greaterThan(cancelRogue));
    expect(rehydrate, greaterThan(reschedule));
    expect(
      forgetLegacy,
      greaterThan(rehydrate),
      reason:
          'rehydration may observe stale legacy parent rows, so transport handles must be fenced before restoring legacy projections',
    );
    expect(
      restore,
      greaterThan(forgetLegacy),
      reason:
          'the original legacy DB projection can be restored only after plugin rescheduling and Transfer fencing are complete',
    );

    expect(
      helper,
      contains('task.group == FileDownloader.chunkGroup'),
      reason:
          'rogue cleanup must target only background_downloader generated chunks, never animewitcher_parts legacy writers',
    );
    expect(helper, contains('downloadInternalParentTaskId(task)'));

    final listenerFence = source.indexOf("'startup.legacyPluginUpdateIgnored'");
    expect(listenerFence, greaterThanOrEqualTo(0));
    expect(
      listenerFence,
      lessThan(startHelper),
      reason:
          'startup listener must fence legacy parent/chunk callbacks before plugin recovery starts',
    );

    final initializeStart = source.indexOf('Future<void> _initialize() async {');
    final initializeEnd = source.indexOf(
      'Future<void> _startPluginExecutor() async {',
      initializeStart,
    );
    final initialize = source.substring(initializeStart, initializeEnd);
    expect(
      initialize.indexOf('await _startPluginExecutor()'),
      lessThan(
        initialize.indexOf('await _serializeQueue(_recoverPersistedDownloads)'),
      ),
    );
  });
}
