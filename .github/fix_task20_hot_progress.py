from pathlib import Path

service = Path('lib/core/services/download_service.dart')
text = service.read_text()
old = '''          final knownTotal = knownDownloadSize(<int?>[\n            update.expectedFileSize,\n            _telemetry.expectedBytesFor(update.task.taskId),\n            previous?.totalSize,\n          ]);\n'''
new = '''          final incomingTotal = knownDownloadSize(<int?>[\n            update.expectedFileSize,\n            _telemetry.expectedBytesFor(update.task.taskId),\n          ]);\n          final knownTotal = keepLastKnownExpectedBytes(\n            incomingExpectedBytes: incomingTotal,\n            lastKnownExpectedBytes: previous?.totalSize,\n          );\n'''
if text.count(old) != 1:
    raise SystemExit(f'hot progress total anchor count={text.count(old)}')
text = text.replace(old, new, 1)
service.write_text(text)

test = Path('test/core/services/download_expected_size_authority_test.dart')
text = test.read_text().replace('\n// hot progress RED trigger\n', '\n')
test.write_text(text)

# trigger one-shot workflow after its definition exists
