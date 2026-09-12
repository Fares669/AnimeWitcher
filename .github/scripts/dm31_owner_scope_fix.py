from pathlib import Path

path = Path('lib/core/services/download_service.dart')
source = path.read_text()

outer_old = '''      int? refreshDescriptorGeneration;

      if (kDebugMode) debugPrint('[DownloadService] Enqueuing task...');
'''
outer_new = '''      int? refreshDescriptorGeneration;
      String? refreshDescriptorOwnerTaskId;

      if (kDebugMode) debugPrint('[DownloadService] Enqueuing task...');
'''
if 'String? refreshDescriptorOwnerTaskId;' not in source:
    if outer_old not in source:
        raise SystemExit('DM-31 owner rollback scope anchor drift')
    source = source.replace(outer_old, outer_new, 1)

transfer_anchor = '''        final transferTask = await _adaptiveTaskForFreshStart(
          task,
          knownTotalBytes: expectedBytes,
        );
'''
transfer_new = transfer_anchor + '''        refreshDescriptorOwnerTaskId = transferTask.taskId;
'''
if 'refreshDescriptorOwnerTaskId = transferTask.taskId;' not in source:
    if transfer_anchor not in source:
        raise SystemExit('DM-31 transfer owner anchor drift')
    source = source.replace(transfer_anchor, transfer_new, 1)

rollback_old = '''        if (refreshDescriptorGeneration != null) {
          await _ref
              .read(downloadUrlRefreshStoreProvider)
              .removeForOwnerGeneration(
                trackingUrl ?? url,
                transferTask.taskId,
                refreshDescriptorGeneration,
              );
        }
'''
rollback_new = '''        if (refreshDescriptorGeneration != null &&
            refreshDescriptorOwnerTaskId != null) {
          await _ref
              .read(downloadUrlRefreshStoreProvider)
              .removeForOwnerGeneration(
                trackingUrl ?? url,
                refreshDescriptorOwnerTaskId,
                refreshDescriptorGeneration,
              );
        }
'''
if rollback_old in source:
    source = source.replace(rollback_old, rollback_new, 1)
elif 'refreshDescriptorOwnerTaskId,' not in source:
    raise SystemExit('DM-31 owner rollback block drift')

path.write_text(source)
