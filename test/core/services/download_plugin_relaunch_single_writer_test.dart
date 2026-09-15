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
      reason: 'resume must not getOrStart a replacement parent from child-only evidence',
    );
  });

  test('startup delegates killed-task reschedule before logical recovery', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final startHelper = source.indexOf('Future<void> _startPluginExecutor() async {');
    final startHelperEnd = source.indexOf(
      '/// Test hook that replaces [FileDownloader.configure]',
      startHelper,
    );
    expect(startHelper, greaterThanOrEqualTo(0));
    expect(startHelperEnd, greaterThan(startHelper));
    final helper = source.substring(startHelper, startHelperEnd);
    expect(helper, contains('FileDownloader().start('));
    expect(helper, contains('doRescheduleKilledTasks: true'));
    expect(helper, contains('_nativeTransport.rehydrate('));

    final initializeStart = source.indexOf('Future<void> _initialize() async {');
    final initializeEnd = source.indexOf(
      'Future<void> _startPluginExecutor() async {',
      initializeStart,
    );
    final initialize = source.substring(initializeStart, initializeEnd);
    expect(
      initialize.indexOf('await _startPluginExecutor()'),
      lessThan(initialize.indexOf('await _serializeQueue(_recoverPersistedDownloads)')),
    );
  });
}

// Task 23 RED trigger
