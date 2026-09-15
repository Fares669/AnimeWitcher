from pathlib import Path

resume = Path('lib/core/utils/download_resume.dart')
text = resume.read_text()
anchor = '''int authoritativeLifecycleExpectedBytes({\n  int? jobExpectedBytes,\n  int? fingerprintExpectedBytes,\n  int? metadataExpectedBytes,\n  int? databaseExpectedBytes,\n  int? telemetryExpectedBytes,\n  int? projectedExpectedBytes,\n}) => knownDownloadSize(<int?>[\n  jobExpectedBytes,\n  fingerprintExpectedBytes,\n  metadataExpectedBytes,\n  databaseExpectedBytes,\n  telemetryExpectedBytes,\n  projectedExpectedBytes,\n]);\n'''
addition = anchor + '''\n/// Keep presentation-level expected bytes monotonic within one logical task.\n/// Plugin parallel callbacks may temporarily expose a child-derived total; that\n/// must not shrink a previously published logical resource size. Lifecycle\n/// persistence remains governed by [authoritativeLifecycleExpectedBytes].\nint keepLastKnownExpectedBytes({\n  required int incomingExpectedBytes,\n  int? lastKnownExpectedBytes,\n}) {\n  final incoming = incomingExpectedBytes > 0 ? incomingExpectedBytes : -1;\n  final previous = (lastKnownExpectedBytes ?? -1) > 0\n      ? lastKnownExpectedBytes!\n      : -1;\n  if (previous > 0 && (incoming <= 0 || incoming < previous)) return previous;\n  if (incoming > 0) return incoming;\n  return previous;\n}\n'''
if text.count(anchor) != 1:
    raise SystemExit(f'authoritative helper anchor count={text.count(anchor)}')
text = text.replace(anchor, addition, 1)
resume.write_text(text)

service = Path('lib/core/services/download_service.dart')
text = service.read_text()

old_saved = '''    final totalSize = knownDownloadSize([\n      current?.totalSize,\n      _telemetry.expectedBytesFor(task.taskId),\n      record?.expectedFileSize,\n      downloadMetadataExpectedBytes(metadata),\n      job?.expectedBytes,\n    ]);\n'''
new_saved = '''    final totalSize = authoritativeLifecycleExpectedBytes(\n      jobExpectedBytes: job?.expectedBytes,\n      fingerprintExpectedBytes: job?.fingerprint?.expectedBytes,\n      metadataExpectedBytes: downloadMetadataExpectedBytes(metadata),\n      databaseExpectedBytes: record?.expectedFileSize,\n      telemetryExpectedBytes: _telemetry.expectedBytesFor(task.taskId),\n      projectedExpectedBytes: current?.totalSize,\n    );\n'''
if text.count(old_saved) != 1:
    raise SystemExit(f'saved progress total anchor count={text.count(old_saved)}')
text = text.replace(old_saved, new_saved, 1)

old_preserve = '''    final totalSize = knownDownloadSize([\n      current?.totalSize,\n      record?.expectedFileSize,\n      downloadMetadataExpectedBytes(metadata),\n    ]);\n\n    // Never delete the DB record, metadata, or partial file here — only mark\n'''
new_preserve = '''    final job = await _jobStore.get(task.taskId);\n    final totalSize = authoritativeLifecycleExpectedBytes(\n      jobExpectedBytes: job?.expectedBytes,\n      fingerprintExpectedBytes: job?.fingerprint?.expectedBytes,\n      metadataExpectedBytes: downloadMetadataExpectedBytes(metadata),\n      databaseExpectedBytes: record?.expectedFileSize,\n      telemetryExpectedBytes: _telemetry.expectedBytesFor(task.taskId),\n      projectedExpectedBytes: current?.totalSize,\n    );\n\n    // Never delete the DB record, metadata, or partial file here — only mark\n'''
if text.count(old_preserve) != 1:
    raise SystemExit(f'preserve total anchor count={text.count(old_preserve)}')
text = text.replace(old_preserve, new_preserve, 1)

old_publish = '''    final knownTotal = knownDownloadSize(<int?>[\n      totalSize,\n      _telemetry.expectedBytesFor(taskId),\n      previous?.totalSize,\n    ]);\n'''
new_publish = '''    final incomingTotal = knownDownloadSize(<int?>[\n      totalSize,\n      _telemetry.expectedBytesFor(taskId),\n    ]);\n    final knownTotal = keepLastKnownExpectedBytes(\n      incomingExpectedBytes: incomingTotal,\n      lastKnownExpectedBytes: previous?.totalSize,\n    );\n'''
if text.count(old_publish) != 1:
    raise SystemExit(f'publish total anchor count={text.count(old_publish)}')
text = text.replace(old_publish, new_publish, 1)
service.write_text(text)

test = Path('test/core/services/download_expected_size_authority_test.dart')
text = test.read_text().replace('\n// lifecycle RED trigger\n', '\n')
test.write_text(text)

# trigger one-shot workflow after its definition exists
