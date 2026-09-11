from pathlib import Path
path = Path('test/core/services/persistent_parallel_download_test.dart')
text = path.read_text()
marker = "  test('five parts cover each byte once', () async {\n"
test = r"""  test('multipart manifest persists a reconstructable parent descriptor', () async {
    expect(await coordinator.start(parent, 100), isTrue);
    final manifest = File('${await parent.filePath()}.parts/manifest.json');
    final decoded = jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;

    expect(decoded['schemaVersion'], 6);
    expect(decoded['parentTask'], isA<Map>());
    final restored = Task.createFromJson(
      Map<String, dynamic>.from(decoded['parentTask'] as Map),
    );
    expect(restored, isA<ParallelDownloadTask>());
    expect(restored.taskId, parent.taskId);
    expect(restored.url, parent.url);
    expect(restored.filename, parent.filename);
  });

"""
if marker not in text:
    raise SystemExit('test insertion marker not found')
if 'multipart manifest persists a reconstructable parent descriptor' in text:
    raise SystemExit('RED test already present')
path.write_text(text.replace(marker, test + marker, 1))
