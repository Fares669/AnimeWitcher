from pathlib import Path
import sys

TRANSPORT = Path('lib/core/services/download_transport.dart')
SERVICE = Path('lib/core/services/download_service.dart')
TEST = Path('test/core/services/download_cancel_settlement_test.dart')
GUARD = Path('test/core/services/download_cancel_ownership_guard_test.dart')

TEST_CONTENT = r'''import 'package:animewitcher/core/services/download_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveDownloadCancelCommand', () {
    test('positive executor acknowledgement is canceled', () {
      expect(
        resolveDownloadCancelCommand(
          hadTrackedOwner: true,
          commandSucceeded: true,
          commandThrew: false,
        ),
        DownloadCancelSettlement.canceled,
      );
    });

    test('negative acknowledgement with tracked owner remains stillOwned', () {
      expect(
        resolveDownloadCancelCommand(
          hadTrackedOwner: true,
          commandSucceeded: false,
          commandThrew: false,
        ),
        DownloadCancelSettlement.stillOwned,
      );
    });

    test('negative acknowledgement without owner evidence is unknown', () {
      expect(
        resolveDownloadCancelCommand(
          hadTrackedOwner: false,
          commandSucceeded: false,
          commandThrew: false,
        ),
        DownloadCancelSettlement.unknown,
      );
    });

    test('throw never claims release', () {
      expect(
        resolveDownloadCancelCommand(
          hadTrackedOwner: true,
          commandSucceeded: false,
          commandThrew: true,
        ),
        DownloadCancelSettlement.unknown,
      );
    });
  });
}
'''

GUARD_CONTENT = r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native cancel keeps tracking until independent ownership proof', () {
    final source = File('lib/core/services/download_transport.dart').readAsStringSync();
    final classStart = source.indexOf('class NativeSingleDownloadTransport implements DownloadTransport');
    final start = source.indexOf('Future<DownloadCancelSettlement> cancel(', classStart);
    final end = source.indexOf('\n  void forget(', start);
    expect(classStart, greaterThanOrEqualTo(0));
    expect(start, greaterThan(classStart));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);
    expect(body, isNot(contains('_detach(task.taskId)')));
    expect(body, contains('resolveDownloadCancelCommand('));
    expect(body, contains('hadTrackedOwner: transfer != null'));
    expect(body, contains('commandSucceeded: canceled'));
    expect(body, contains('commandThrew: true'));
  });

  test('service gates destructive cancel cleanup on runtime notOwned proof', () {
    final source = File('lib/core/services/download_service.dart').readAsStringSync();
    expect(source, contains('Future<DownloadRuntimeOwnership> _waitForCancelOwnershipRelease('));
    expect(source, contains("'cancel.ownershipUnsettled'"));
    expect(source, contains('if (cancelOwnership != DownloadRuntimeOwnership.notOwned)'));
    expect(source, contains('await _jobStore.remove(taskId);'));

    final callbackStart = source.indexOf('cancelParts: (ids) async {');
    final callbackEnd = source.indexOf('saveRecord:', callbackStart);
    expect(callbackStart, greaterThanOrEqualTo(0));
    expect(callbackEnd, greaterThan(callbackStart));
    final callback = source.substring(callbackStart, callbackEnd);
    expect(callback, contains('await _waitForCancelOwnershipRelease(id)'));
    expect(callback, contains('Multipart cancel ownership did not settle'));
  });
}
'''


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one match, got {count}')
    return text.replace(old, new, 1)

if len(sys.argv) != 2 or sys.argv[1] not in {'tests', 'apply'}:
    raise SystemExit('usage: tests|apply')

TEST.write_text(TEST_CONTENT)
GUARD.write_text(GUARD_CONTENT)
if sys.argv[1] == 'tests':
    raise SystemExit(0)

transport = TRANSPORT.read_text()
old_enum = '''enum DownloadRuntimeOwnership { owned, notOwned, settling, unknown }\n\nextension DownloadRuntimeOwnershipSafety on DownloadRuntimeOwnership {\n'''
new_enum = '''enum DownloadRuntimeOwnership { owned, notOwned, settling, unknown }\n\n/// Result of issuing a cancellation command. None of these values, including\n/// [canceled], independently proves that the executor released file ownership;\n/// callers must still obtain a runtime [DownloadRuntimeOwnership.notOwned]\n/// acknowledgement before forgetting handles or deleting durable evidence.\nenum DownloadCancelSettlement { canceled, alreadyGone, stillOwned, unknown }\n\nDownloadCancelSettlement resolveDownloadCancelCommand({\n  required bool hadTrackedOwner,\n  required bool commandSucceeded,\n  required bool commandThrew,\n}) {\n  if (commandThrew) return DownloadCancelSettlement.unknown;\n  if (commandSucceeded) return DownloadCancelSettlement.canceled;\n  return hadTrackedOwner\n      ? DownloadCancelSettlement.stillOwned\n      : DownloadCancelSettlement.unknown;\n}\n\nextension DownloadRuntimeOwnershipSafety on DownloadRuntimeOwnership {\n'''
transport = replace_once(transport, old_enum, new_enum, 'cancel settlement enum')
transport = replace_once(
    transport,
    '  Future<bool> cancel(DownloadTask task);',
    '  Future<DownloadCancelSettlement> cancel(DownloadTask task);',
    'transport interface cancel type',
)
old_cancel = '''  @override\n  Future<bool> cancel(DownloadTask task) async {\n    if (!isNativeSingleDownloadTask(task)) return false;\n    final transfer = handleFor(task.taskId);\n    try {\n      final canceled = transfer != null\n          ? await transfer.cancel()\n          : await _downloader.cancelTaskWithId(task.taskId);\n      _detach(task.taskId);\n      return canceled;\n    } catch (_) {\n      return false;\n    }\n  }\n'''
new_cancel = '''  @override\n  Future<DownloadCancelSettlement> cancel(DownloadTask task) async {\n    if (!isNativeSingleDownloadTask(task)) {\n      return DownloadCancelSettlement.unknown;\n    }\n    final transfer = handleFor(task.taskId);\n    try {\n      final canceled = transfer != null\n          ? await transfer.cancel()\n          : await _downloader.cancelTaskWithId(task.taskId);\n      // Never detach here. A true command result is an acknowledgement, not\n      // proof that URLSession stopped writing. DownloadService forgets this\n      // handle only after its independent runtime oracle returns notOwned.\n      return resolveDownloadCancelCommand(\n        hadTrackedOwner: transfer != null,\n        commandSucceeded: canceled,\n        commandThrew: false,\n      );\n    } catch (_) {\n      // Preserve any handle/subscription on uncertainty. Forgetting it here can\n      // permit a second writer while the old executor is still alive.\n      return resolveDownloadCancelCommand(\n        hadTrackedOwner: transfer != null,\n        commandSucceeded: false,\n        commandThrew: true,\n      );\n    }\n  }\n'''
transport = replace_once(transport, old_cancel, new_cancel, 'native cancel implementation')
TRANSPORT.write_text(transport)

service = SERVICE.read_text()
old_cancel_parts = '''      cancelParts: (ids) async {\n        for (final id in ids) {\n          await _rangeTransfers.stop(id);\n        }\n        await FileDownloader().cancelTasksWithIds(ids);\n        for (final id in ids) {\n          await FileDownloader().database.deleteRecordWithId(id);\n        }\n      },\n'''
new_cancel_parts = '''      cancelParts: (ids) async {\n        for (final id in ids) {\n          await _rangeTransfers.stop(id);\n        }\n        await FileDownloader().cancelTasksWithIds(ids);\n        final unsettled = <String>[];\n        for (final id in ids) {\n          final ownership = await _waitForCancelOwnershipRelease(id);\n          if (ownership != DownloadRuntimeOwnership.notOwned) {\n            unsettled.add(id);\n            continue;\n          }\n          await FileDownloader().database.deleteRecordWithId(id);\n        }\n        if (unsettled.isNotEmpty) {\n          throw StateError(\n            'Multipart cancel ownership did not settle: ${unsettled.join(',')}',\n          );\n        }\n      },\n'''
service = replace_once(service, old_cancel_parts, new_cancel_parts, 'multipart cancel callback')

runtime_anchor = '''  Future<void> _reconcileTransferOwnership() async {\n'''
runtime_helper = '''  Future<DownloadRuntimeOwnership> _waitForCancelOwnershipRelease(\n    String taskId, {\n    int attempts = 10,\n    Duration delay = const Duration(milliseconds: 100),\n  }) async {\n    var ownership = await _runtimeOwnershipFor(taskId);\n    for (var attempt = 1;\n        attempt < attempts && ownership != DownloadRuntimeOwnership.notOwned;\n        attempt++) {\n      await Future<void>.delayed(delay);\n      ownership = await _runtimeOwnershipFor(taskId);\n    }\n    return ownership;\n  }\n\n'''
if service.count(runtime_anchor) != 1:
    raise SystemExit('runtime helper anchor missing/ambiguous')
service = service.replace(runtime_anchor, runtime_helper + runtime_anchor, 1)

old_single = '''        } else if (parentRecord?.task is DownloadTask &&\n            isNativeSingleDownloadTask(parentRecord!.task)) {\n          await _nativeTransport.cancel(parentRecord.task as DownloadTask);\n          ids.remove(taskId);\n        }\n        if (ids.isNotEmpty) {\n          await FileDownloader().cancelTasksWithIds(ids.toList());\n        }\n        _nativeTransport.forget(taskId);\n        _userPausedIds.remove(taskId);\n'''
new_single = '''        } else if (parentRecord?.task is DownloadTask &&\n            isNativeSingleDownloadTask(parentRecord!.task)) {\n          final settlement = await _nativeTransport.cancel(\n            parentRecord.task as DownloadTask,\n          );\n          diagnosticLog.record('cancel.commandSettlement', {\n            'taskId': taskId,\n            'settlement': settlement.name,\n          });\n          // Do not issue a second bulk cancel for this same single-file owner.\n          ids.remove(taskId);\n        }\n        if (ids.isNotEmpty) {\n          await FileDownloader().cancelTasksWithIds(ids.toList());\n        }\n\n        // Command acknowledgement is not ownership acknowledgement. Keep the\n        // durable cancel tombstone, plugin row, metadata and Transfer handle if\n        // the runtime oracle cannot independently prove release. A later\n        // reconcile/repeated cancel can settle cleanup safely.\n        final cancelOwnership = await _waitForCancelOwnershipRelease(taskId);\n        if (cancelOwnership != DownloadRuntimeOwnership.notOwned) {\n          diagnosticLog.record('cancel.ownershipUnsettled', {\n            'taskId': taskId,\n            'ownership': cancelOwnership.name,\n          });\n          await _persistNativeWaitingSnapshot();\n          if (notifyContinuedProcessing) {\n            await _syncSessionOverlay(completedSuccess: false);\n          }\n          return;\n        }\n        _nativeTransport.forget(taskId);\n        _userPausedIds.remove(taskId);\n'''
service = replace_once(service, old_single, new_single, 'single cancellation cleanup gate')
SERVICE.write_text(service)
