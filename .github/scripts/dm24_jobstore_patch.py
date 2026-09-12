from pathlib import Path

path = Path('lib/core/services/download_job_store.dart')
source = path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global source
    count = source.count(old)
    if count != 1:
        raise SystemExit(f'{label} anchor mismatch: {count}')
    source = source.replace(old, new, 1)

replace_once(
    'const int kDownloadJobSchemaVersion = 4;',
    'const int kDownloadJobSchemaVersion = 5;',
    'schema version',
)

replace_once(
    '''  const DownloadJobRecord({\n    required this.taskId,\n    required this.trackingUrl,''',
    '''  const DownloadJobRecord({\n    required this.taskId,\n    this.logicalId,\n    required this.trackingUrl,''',
    'record constructor',
)
replace_once(
    '''  final String taskId;\n  final String trackingUrl;''',
    '''  final String taskId;\n\n  /// Stable logical episode identity. Multiple execution task IDs may point to\n  /// the same value across retry/adoption generations. Legacy rows can be null\n  /// until presentation metadata is available to migrate them safely.\n  final String? logicalId;\n\n  final String trackingUrl;''',
    'record field',
)
replace_once(
    '''  DownloadJobRecord copyWith({\n    String? trackingUrl,''',
    '''  DownloadJobRecord copyWith({\n    String? logicalId,\n    String? trackingUrl,''',
    'copyWith parameter',
)
replace_once(
    '''  }) => DownloadJobRecord(\n    taskId: taskId,\n    trackingUrl: trackingUrl ?? this.trackingUrl,''',
    '''  }) => DownloadJobRecord(\n    taskId: taskId,\n    logicalId: logicalId ?? this.logicalId,\n    trackingUrl: trackingUrl ?? this.trackingUrl,''',
    'copyWith record',
)
replace_once(
    '''    'schemaVersion': kDownloadJobSchemaVersion,\n    'taskId': taskId,\n    'trackingUrl': trackingUrl,''',
    '''    'schemaVersion': kDownloadJobSchemaVersion,\n    'taskId': taskId,\n    if (_nonEmptyString(logicalId) != null) 'logicalId': logicalId,\n    'trackingUrl': trackingUrl,''',
    'json encode',
)
replace_once(
    '''    return DownloadJobRecord(\n      taskId: taskId,\n      trackingUrl: trackingUrl,''',
    '''    return DownloadJobRecord(\n      taskId: taskId,\n      logicalId: _nonEmptyString(map['logicalId']),\n      trackingUrl: trackingUrl,''',
    'json decode',
)

replace_once(
    '''  Future<List<DownloadJobRecord>> all() async {\n    final jobs = <DownloadJobRecord>[];\n    for (final raw in await backend.readAll()) {\n      final job = DownloadJobRecord.fromJson(raw);\n      if (job != null) jobs.add(job);\n    }\n    jobs.sort((a, b) => a.updatedAtMillis.compareTo(b.updatedAtMillis));\n    return jobs;\n  }\n''',
    '''  Future<List<DownloadJobRecord>> all() async {\n    final jobs = <DownloadJobRecord>[];\n    for (final raw in await backend.readAll()) {\n      final job = DownloadJobRecord.fromJson(raw);\n      if (job != null) jobs.add(job);\n    }\n    jobs.sort((a, b) => a.updatedAtMillis.compareTo(b.updatedAtMillis));\n    return jobs;\n  }\n\n  /// Returns every execution row currently associated with one logical episode.\n  /// The store intentionally does not collapse them here: DownloadService must\n  /// settle/adopt executor ownership before removing an obsolete task ID.\n  Future<List<DownloadJobRecord>> allForLogicalId(String logicalId) async {\n    final id = logicalId.trim();\n    if (id.isEmpty) return const <DownloadJobRecord>[];\n    final jobs = await all();\n    return jobs\n        .where((job) => _nonEmptyString(job.logicalId) == id)\n        .toList(growable: false);\n  }\n''',
    'allForLogicalId',
)

replace_once(
    '''    final current = await get(taskId);\n    if (current != null) {''',
    '''    final current = await get(taskId);\n    final incomingLogicalId = _nonEmptyString(next.logicalId);\n    final currentLogicalId = _nonEmptyString(current?.logicalId);\n    if (currentLogicalId != null &&\n        incomingLogicalId != null &&\n        currentLogicalId != incomingLogicalId) {\n      return false;\n    }\n    if (current != null) {''',
    'logical id invariant',
)
replace_once(
    '''    final durable = next.copyWith(\n      durableByteProvenance: _normalizedDurableByteProvenance(''',
    '''    final durable = next.copyWith(\n      logicalId: incomingLogicalId ?? currentLogicalId,\n      durableByteProvenance: _normalizedDurableByteProvenance(''',
    'logical id preserve',
)

replace_once(
    '''  Future<bool> checkpoint({\n    required String taskId,\n    required String trackingUrl,\n    required DownloadJobState state,''',
    '''  Future<bool> checkpoint({\n    required String taskId,\n    String? logicalId,\n    required String trackingUrl,\n    required DownloadJobState state,''',
    'checkpoint parameter',
)
replace_once(
    '''        ? DownloadJobRecord(\n            taskId: id,\n            trackingUrl: tracking,''',
    '''        ? DownloadJobRecord(\n            taskId: id,\n            logicalId: _nonEmptyString(logicalId),\n            trackingUrl: tracking,''',
    'checkpoint create',
)
replace_once(
    '''        : current.copyWith(\n            state: state,''',
    '''        : current.copyWith(\n            logicalId: _nonEmptyString(logicalId),\n            state: state,''',
    'checkpoint update',
)

path.write_text(source)
