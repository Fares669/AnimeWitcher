from pathlib import Path

resume = Path('lib/core/utils/download_resume.dart')
text = resume.read_text()
needle = '''int knownDownloadSize(Iterable<int?> candidates) {\n  for (final bytes in candidates) {\n    if (bytes != null && bytes > 0) return bytes;\n  }\n  return -1;\n}\n'''
replacement = needle + '''\n/// Select the expected resource size used for lifecycle checkpoints.\n///\n/// Durable logical/resource identity must outrank plugin/UI telemetry because\n/// parallel chunk callbacks can temporarily expose a child-derived total. A\n/// smaller transient total must never rewrite the resource length already\n/// accepted by JobStore.\nint authoritativeLifecycleExpectedBytes({\n  int? jobExpectedBytes,\n  int? fingerprintExpectedBytes,\n  int? metadataExpectedBytes,\n  int? databaseExpectedBytes,\n  int? telemetryExpectedBytes,\n  int? projectedExpectedBytes,\n}) => knownDownloadSize(<int?>[\n  jobExpectedBytes,\n  fingerprintExpectedBytes,\n  metadataExpectedBytes,\n  databaseExpectedBytes,\n  telemetryExpectedBytes,\n  projectedExpectedBytes,\n]);\n'''
if text.count(needle) != 1:
    raise SystemExit(f'knownDownloadSize anchor count={text.count(needle)}')
text = text.replace(needle, replacement, 1)
resume.write_text(text)

service = Path('lib/core/services/download_service.dart')
text = service.read_text()
old = '''        final totalSize = knownDownloadSize([\n          current?.totalSize,\n          _telemetry.expectedBytesFor(taskId),\n          record?.expectedFileSize,\n          downloadMetadataExpectedBytes(metadata),\n        ]);\n'''
new = '''        final job = await _jobStore.get(taskId);\n        final totalSize = authoritativeLifecycleExpectedBytes(\n          jobExpectedBytes: job?.expectedBytes,\n          fingerprintExpectedBytes: job?.fingerprint?.expectedBytes,\n          metadataExpectedBytes: downloadMetadataExpectedBytes(metadata),\n          databaseExpectedBytes: record?.expectedFileSize,\n          telemetryExpectedBytes: _telemetry.expectedBytesFor(taskId),\n          projectedExpectedBytes: current?.totalSize,\n        );\n'''
if text.count(old) != 1:
    raise SystemExit(f'pause total-size anchor count={text.count(old)}')
text = text.replace(old, new, 1)
service.write_text(text)

test = Path('test/core/services/download_expected_size_authority_test.dart')
text = test.read_text().replace('\n// RED verification trigger\n', '\n')
test.write_text(text)

# trigger one-shot workflow after its definition exists
