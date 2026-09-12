from pathlib import Path
import runpy

runpy.run_path('.github/scripts/dm31_patch.py', run_name='__main__')

# Legacy tests/callers intentionally omit generation. They deserialize/construct
# as generation zero until DownloadService takes ownership and rewrites them.
path = Path('lib/core/services/download_url_refresh.dart')
source = path.read_text()
source = source.replace('    required this.generation,\n', '    this.generation = 0,\n', 1)
path.write_text(source)

# The base patch originally declared refreshDescriptorGeneration inside the
# inner persistence try, while rollback runs from the surrounding catch. Keep
# the generation fence alive for the complete start transaction so rollback can
# remove only the descriptor generation this attempt actually committed.
path = Path('lib/core/services/download_service.dart')
source = path.read_text()
inner_declaration = '        int? refreshDescriptorGeneration;\n'
outer_anchor = '''      if (kDebugMode) debugPrint('[DownloadService] Enqueuing task...');

      // Create the directory if it doesn't exist
'''
outer_replacement = '''      int? refreshDescriptorGeneration;

      if (kDebugMode) debugPrint('[DownloadService] Enqueuing task...');

      // Create the directory if it doesn't exist
'''
if source.count(inner_declaration) != 1:
    raise SystemExit('DM-31 refresh descriptor generation declaration drift')
if outer_anchor not in source:
    raise SystemExit('DM-31 outer generation scope anchor drift')
source = source.replace(inner_declaration, '', 1)
source = source.replace(outer_anchor, outer_replacement, 1)
path.write_text(source)

# A task-local generation is not globally unique: a replacement task starts at
# generation zero again. Persist the canonical logical identity plus the task
# that currently owns the descriptor, and make ordinary save/remove operations
# prove that owner before they can mutate durable state.
path = Path('lib/core/services/download_url_refresh.dart')
source = path.read_text()
if 'this.ownerTaskId,' not in source:
    constructor_anchor = '''    this.generation = 0,
    this.quality,
'''
    constructor_replacement = '''    this.generation = 0,
    this.ownerTaskId,
    this.logicalId,
    this.quality,
'''
    if constructor_anchor not in source:
        raise SystemExit('DM-31 owner constructor anchor drift')
    source = source.replace(constructor_anchor, constructor_replacement, 1)

    field_anchor = '''  final int updatedAtMillis;
  final int generation;

  Map<String, Object?> toJson() => <String, Object?>{
'''
    field_replacement = '''  final int updatedAtMillis;
  final int generation;
  final String? ownerTaskId;
  final String? logicalId;

  Map<String, Object?> toJson() => <String, Object?>{
'''
    if field_anchor not in source:
        raise SystemExit('DM-31 owner field anchor drift')
    source = source.replace(field_anchor, field_replacement, 1)

    json_anchor = '''    'updatedAtMillis': updatedAtMillis,
    'generation': generation,
  };
'''
    json_replacement = '''    'updatedAtMillis': updatedAtMillis,
    'generation': generation,
    if (ownerTaskId?.trim().isNotEmpty ?? false) 'ownerTaskId': ownerTaskId,
    if (logicalId?.trim().isNotEmpty ?? false) 'logicalId': logicalId,
  };
'''
    if json_anchor not in source:
        raise SystemExit('DM-31 owner json anchor drift')
    source = source.replace(json_anchor, json_replacement, 1)

    decode_anchor = '''      generation: _int(map['generation']),
    );
'''
    decode_replacement = '''      generation: _int(map['generation']),
      ownerTaskId: _string(map['ownerTaskId']),
      logicalId: _string(map['logicalId']),
    );
'''
    if decode_anchor not in source:
        raise SystemExit('DM-31 owner decode anchor drift')
    source = source.replace(decode_anchor, decode_replacement, 1)

old_save = '''  Future<bool> save(DownloadUrlRefreshDescriptor descriptor) =>
      _serialize(() async {
        if (descriptor.trackingUrl.trim().isEmpty ||
            descriptor.providerId.trim().isEmpty ||
            descriptor.source.trim().isEmpty) {
          return false;
        }
        final key = keyFor(descriptor.trackingUrl);
        final existing = DownloadUrlRefreshDescriptor.fromJson(
          await backend.read(key),
        );
        if (existing != null && existing.generation > descriptor.generation) {
          return false;
        }
        await backend.write(key, descriptor.toJson());
        return true;
      });
'''
new_save = '''  Future<bool> claimOwnership(DownloadUrlRefreshDescriptor descriptor) =>
      _serialize(() async {
        final ownerTaskId = descriptor.ownerTaskId?.trim();
        final logicalId = descriptor.logicalId?.trim();
        if (descriptor.trackingUrl.trim().isEmpty ||
            descriptor.providerId.trim().isEmpty ||
            descriptor.source.trim().isEmpty ||
            ownerTaskId == null ||
            ownerTaskId.isEmpty ||
            logicalId == null ||
            logicalId.isEmpty) {
          return false;
        }
        final key = keyFor(descriptor.trackingUrl);
        final existing = DownloadUrlRefreshDescriptor.fromJson(
          await backend.read(key),
        );
        final existingLogicalId = existing?.logicalId?.trim();
        if (existingLogicalId != null &&
            existingLogicalId.isNotEmpty &&
            existingLogicalId != logicalId) {
          return false;
        }
        if (existing?.ownerTaskId == ownerTaskId &&
            existing!.generation > descriptor.generation) {
          return false;
        }
        await backend.write(key, descriptor.toJson());
        return true;
      });

  Future<bool> save(DownloadUrlRefreshDescriptor descriptor) =>
      _serialize(() async {
        if (descriptor.trackingUrl.trim().isEmpty ||
            descriptor.providerId.trim().isEmpty ||
            descriptor.source.trim().isEmpty) {
          return false;
        }
        final key = keyFor(descriptor.trackingUrl);
        final existing = DownloadUrlRefreshDescriptor.fromJson(
          await backend.read(key),
        );
        final incomingOwner = descriptor.ownerTaskId?.trim();
        final existingOwner = existing?.ownerTaskId?.trim();

        // Owned descriptors can only be created/replaced through the explicit
        // claim path. This prevents a delayed old task from resurrecting its
        // descriptor after the current owner has deleted it.
        if (existing == null) {
          if (incomingOwner != null && incomingOwner.isNotEmpty) return false;
        } else if (existingOwner != null && existingOwner.isNotEmpty) {
          if (incomingOwner != existingOwner) return false;
          final existingLogicalId = existing.logicalId?.trim();
          final incomingLogicalId = descriptor.logicalId?.trim();
          if (existingLogicalId != null &&
              existingLogicalId.isNotEmpty &&
              incomingLogicalId != existingLogicalId) {
            return false;
          }
        } else if (incomingOwner != null && incomingOwner.isNotEmpty) {
          // Migrating a legacy unowned descriptor to owned state is also a
          // claim operation, never a plain save.
          return false;
        }

        if (existing != null && existing.generation > descriptor.generation) {
          return false;
        }
        await backend.write(key, descriptor.toJson());
        return true;
      });
'''
if 'Future<bool> claimOwnership(' not in source:
    if old_save not in source:
        raise SystemExit('DM-31 owner save anchor drift')
    source = source.replace(old_save, new_save, 1)

old_remove = '''  Future<bool> removeForGeneration(
    String trackingUrl,
    int generation,
  ) => _serialize(() async {
    final key = keyFor(trackingUrl);
    final descriptor = DownloadUrlRefreshDescriptor.fromJson(
      await backend.read(key),
    );
    if (descriptor == null) return true;
    if (descriptor.generation != generation) return false;
    await backend.delete(key);
    return true;
  });
'''
new_remove = '''  Future<bool> removeForGeneration(
    String trackingUrl,
    int generation,
  ) => _serialize(() async {
    final key = keyFor(trackingUrl);
    final descriptor = DownloadUrlRefreshDescriptor.fromJson(
      await backend.read(key),
    );
    if (descriptor == null) return true;
    // Generation-only cleanup is retained for legacy unowned rows only. Once
    // an owner exists, callers must prove the task identity as well.
    if (descriptor.ownerTaskId != null) return false;
    if (descriptor.generation != generation) return false;
    await backend.delete(key);
    return true;
  });

  Future<bool> removeForOwnerGeneration(
    String trackingUrl,
    String ownerTaskId,
    int generation,
  ) => _serialize(() async {
    final key = keyFor(trackingUrl);
    final descriptor = DownloadUrlRefreshDescriptor.fromJson(
      await backend.read(key),
    );
    if (descriptor == null) return true;
    if (descriptor.ownerTaskId?.trim() != ownerTaskId.trim()) return false;
    // A newer same-owner operation may clean an older descriptor after a
    // crash, but a stale operation can never delete a newer generation.
    if (descriptor.generation > generation) return false;
    await backend.delete(key);
    return true;
  });
'''
if 'Future<bool> removeForOwnerGeneration(' not in source:
    if old_remove not in source:
        raise SystemExit('DM-31 owner remove anchor drift')
    source = source.replace(old_remove, new_remove, 1)
path.write_text(source)

# DownloadService is the only authority allowed to claim a descriptor owner.
# Launcher supplies only a draft. The service fills task/logical identity while
# holding its serialized logical-start queue.
path = Path('lib/core/services/download_service.dart')
source = path.read_text()
old_helper = '''  Future<bool> _commitRefreshDescriptorForGeneration(
    DownloadUrlRefreshDescriptor descriptor, {
    required String trackingUrl,
    required int generation,
  }) {
    return _ref.read(downloadUrlRefreshStoreProvider).save(
      DownloadUrlRefreshDescriptor(
        trackingUrl: trackingUrl,
        providerId: descriptor.providerId,
        source: descriptor.source,
        quality: descriptor.quality,
        refreshUrl: descriptor.refreshUrl,
        updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
        generation: generation,
      ),
    );
  }
'''
new_helper = '''  Future<bool> _commitRefreshDescriptorForGeneration(
    DownloadUrlRefreshDescriptor descriptor, {
    required String trackingUrl,
    required String ownerTaskId,
    required String logicalId,
    required int generation,
    bool claimOwnership = false,
  }) {
    final owned = DownloadUrlRefreshDescriptor(
      trackingUrl: trackingUrl,
      providerId: descriptor.providerId,
      source: descriptor.source,
      quality: descriptor.quality,
      refreshUrl: descriptor.refreshUrl,
      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
      generation: generation,
      ownerTaskId: ownerTaskId,
      logicalId: logicalId,
    );
    final store = _ref.read(downloadUrlRefreshStoreProvider);
    return claimOwnership ? store.claimOwnership(owned) : store.save(owned);
  }
'''
if 'required String ownerTaskId,' not in source:
    if old_helper not in source:
        raise SystemExit('DM-31 owner helper anchor drift')
    source = source.replace(old_helper, new_helper, 1)

queued_call = '''          final committed = await _commitRefreshDescriptorForGeneration(
            refreshDescriptor,
            trackingUrl: trackingUrl ?? url,
            generation: 0,
          );
'''
queued_owned = '''          final committed = await _commitRefreshDescriptorForGeneration(
            refreshDescriptor,
            trackingUrl: trackingUrl ?? url,
            ownerTaskId: transferTask.taskId,
            logicalId: logicalId,
            generation: 0,
            claimOwnership: true,
          );
'''
if queued_call in source:
    source = source.replace(queued_call, queued_owned, 1)

running_call = '''          final committed = await _commitRefreshDescriptorForGeneration(
            refreshDescriptor,
            trackingUrl: trackingUrl ?? url,
            generation: startOperation.generation,
          );
'''
running_owned = '''          final committed = await _commitRefreshDescriptorForGeneration(
            refreshDescriptor,
            trackingUrl: trackingUrl ?? url,
            ownerTaskId: transferTask.taskId,
            logicalId: logicalId,
            generation: startOperation.generation,
            claimOwnership: true,
          );
'''
if running_call in source:
    source = source.replace(running_call, running_owned, 1)

rollback_call = '''          await _ref.read(downloadUrlRefreshStoreProvider).removeForGeneration(
            trackingUrl ?? url,
            refreshDescriptorGeneration,
          );
'''
rollback_owned = '''          await _ref
              .read(downloadUrlRefreshStoreProvider)
              .removeForOwnerGeneration(
                trackingUrl ?? url,
                transferTask.taskId,
                refreshDescriptorGeneration,
              );
'''
if rollback_call in source:
    source = source.replace(rollback_call, rollback_owned, 1)

cancel_call = '''      await _ref.read(downloadUrlRefreshStoreProvider).remove(trackingUrl);
'''
cancel_owned = '''      final cancelJob = await _jobStore.get(taskId);
      await _ref
          .read(downloadUrlRefreshStoreProvider)
          .removeForOwnerGeneration(
            trackingUrl,
            taskId,
            cancelJob?.generation ?? 0,
          );
'''
if cancel_call in source:
    source = source.replace(cancel_call, cancel_owned, 1)

gc_call = '''        await refreshStore.remove(job.trackingUrl);
'''
gc_owned = '''        await refreshStore.removeForOwnerGeneration(
          job.trackingUrl,
          job.taskId,
          job.generation,
        );
'''
if gc_call in source:
    source = source.replace(gc_call, gc_owned, 1)

path.write_text(source)
