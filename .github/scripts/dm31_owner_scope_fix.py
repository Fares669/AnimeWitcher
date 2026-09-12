from pathlib import Path

path = Path('lib/core/services/download_service.dart')
source = path.read_text()

# Keep the owner identity alive across the whole start transaction so the
# rollback catch never reaches back into the transferTask local scope.
if 'String? refreshDescriptorOwnerTaskId;' not in source:
    declaration_anchor = '      int? refreshDescriptorGeneration;\n'
    if source.count(declaration_anchor) != 1:
        raise SystemExit('DM-31 owner rollback scope anchor drift')
    source = source.replace(
        declaration_anchor,
        declaration_anchor + '      String? refreshDescriptorOwnerTaskId;\n',
        1,
    )

if 'refreshDescriptorOwnerTaskId = transferTask.taskId;' not in source:
    transfer_anchor = '''        final transferTask = await _adaptiveTaskForFreshStart(
          task,
          knownTotalBytes: expectedBytes,
        );
'''
    if transfer_anchor not in source:
        raise SystemExit('DM-31 transfer owner anchor drift')
    source = source.replace(
        transfer_anchor,
        transfer_anchor + '        refreshDescriptorOwnerTaskId = transferTask.taskId;\n',
        1,
    )

# dm31_patch_v2 already converts rollback to removeForOwnerGeneration. Only the
# owner argument needs widening out of transferTask's local scope. Matching the
# argument pair is intentionally narrower and less formatting-sensitive than
# replacing the whole rollback block.
rollback_argument = '''                transferTask.taskId,
                refreshDescriptorGeneration,
'''
rollback_owner_argument = '''                refreshDescriptorOwnerTaskId,
                refreshDescriptorGeneration,
'''
if rollback_argument in source:
    source = source.replace(rollback_argument, rollback_owner_argument, 1)
elif rollback_owner_argument not in source:
    raise SystemExit('DM-31 owner rollback argument drift')

path.write_text(source)
