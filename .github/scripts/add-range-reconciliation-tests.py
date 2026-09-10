from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected exactly one match, found {count}')
    file.write_text(text.replace(old, new, 1))

path = 'test/core/services/download_range_transfer_test.dart'

replace_once(
    path,
    "      if (isProbe) {\n        response.statusCode = 206;\n",
    "      if (isProbe && responseMode == 'probe-416') {\n        response.statusCode = 416;\n        response.headers.set('content-range', 'bytes */10');\n        await response.close();\n        return;\n      }\n\n      if (isProbe) {\n        response.statusCode = 206;\n",
)

replace_once(
    path,
    "      transferAttempts++;\n      if (responseMode == 'long-backoff' ||\n",
    "      transferAttempts++;\n      if (responseMode == 'startup-416' ||\n          (responseMode == 'reconnect-416' && transferAttempts == 2)) {\n        response.statusCode = 416;\n        response.headers.set('content-range', 'bytes */10');\n        await response.close();\n        return;\n      }\n      if (responseMode == 'startup-416-malformed') {\n        response.statusCode = 416;\n        await response.close();\n        return;\n      }\n      if (responseMode == 'ignored-no-content-range') {\n        response.statusCode = 200;\n        response.add(List<int>.generate(10, (i) => 30 + i));\n        await response.close();\n        return;\n      }\n      if (responseMode == 'missing-content-range') {\n        response.statusCode = 206;\n        response.headers.set('etag', '\"v1\"');\n        response.add(\n          List<int>.generate(\n            requestedEnd - requestedStart + 1,\n            (i) => requestedStart + i,\n          ),\n        );\n        await response.close();\n        return;\n      }\n      if (responseMode == 'long-backoff' ||\n",
)

replace_once(
    path,
    "      final responseStart = responseMode == 'wrong-start'\n          ? requestedStart - 1\n          : requestedStart;\n      response.headers.set(\n        'content-range',\n        'bytes $responseStart-$requestedEnd/10',\n      );\n",
    "      final responseStart = responseMode == 'wrong-start'\n          ? requestedStart - 1\n          : requestedStart;\n      final responseEnd = responseMode == 'wrong-end'\n          ? requestedEnd - 1\n          : requestedEnd;\n      final responseTotal = responseMode == 'wrong-total' ? 11 : 10;\n      response.headers.set(\n        'content-range',\n        'bytes $responseStart-$responseEnd/$responseTotal',\n      );\n",
)

replace_once(
    path,
    "      if ((responseMode == 'truncate-once' ||\n              responseMode == 'reconnect-retry') &&\n          transferAttempts == 1) {\n",
    "      if ((responseMode == 'truncate-once' ||\n              responseMode == 'reconnect-retry' ||\n              responseMode == 'reconnect-416') &&\n          transferAttempts == 1) {\n",
)

replace_once(
    path,
    "  for (final mode in ['ignored', 'wrong-start']) {\n",
    "  for (final mode in [\n    'ignored',\n    'ignored-no-content-range',\n    'missing-content-range',\n    'wrong-start',\n    'wrong-end',\n    'wrong-total',\n  ]) {\n",
)

insert_after = "  test(\n    'bounded reconnects keep durable bytes when the body stays truncated',\n"
if insert_after not in Path(path).read_text():
    raise SystemExit('range test insertion anchor missing')
extra = r'''  test('startup 416 reports exact resource size without touching bytes', () async {
    responseMode = 'startup-416';
    DownloadRangeFailure? failure;
    expect(
      await runner.start(
        id: 'episode',
        url: url,
        headers: {},
        file: partial,
        existingBytes: 3,
        expectedBytes: 10,
        onState: (_, _, _) async {},
        onPaused: (_, _) async {},
        onFailure: (value) async => failure = value,
      ),
      isFalse,
    );
    expect(failure?.action, DownloadFailureAction.reconcileRange);
    expect(failure?.statusCode, 416);
    expect(failure?.resourceSize, 10);
    expect(await partial.readAsBytes(), [0, 1, 2]);
    expect(runner.isActive('episode'), isFalse);
  });

  test('malformed 416 never invents a resource size', () async {
    responseMode = 'startup-416-malformed';
    DownloadRangeFailure? failure;
    expect(
      await runner.start(
        id: 'episode',
        url: url,
        headers: {},
        file: partial,
        existingBytes: 3,
        expectedBytes: 10,
        onState: (_, _, _) async {},
        onPaused: (_, _) async {},
        onFailure: (value) async => failure = value,
      ),
      isFalse,
    );
    expect(failure?.action, DownloadFailureAction.reconcileRange);
    expect(failure?.resourceSize, -1);
    expect(await partial.readAsBytes(), [0, 1, 2]);
  });

  test('416 during prefix validation parks before any append', () async {
    responseMode = 'probe-416';
    DownloadRangeFailure? failure;
    expect(
      await runner.start(
        id: 'episode',
        url: url,
        headers: {},
        file: partial,
        existingBytes: 3,
        expectedBytes: 10,
        onState: (_, _, _) async {},
        onPaused: (_, _) async {},
        onFailure: (value) async => failure = value,
      ),
      isFalse,
    );
    expect(ranges, ['bytes=0-2']);
    expect(failure?.action, DownloadFailureAction.reconcileRange);
    expect(failure?.resourceSize, 10);
    expect(await partial.readAsBytes(), [0, 1, 2]);
  });

  test('416 on reconnect preserves newly durable bytes for reconciliation', () async {
    responseMode = 'reconnect-416';
    final paused = Completer<int>();
    DownloadRangeFailure? failure;
    expect(
      await runner.start(
        id: 'episode',
        url: url,
        headers: {},
        file: partial,
        existingBytes: 3,
        expectedBytes: 10,
        onState: (_, _, _) async {},
        onPaused: (written, _) async {
          if (!paused.isCompleted) paused.complete(written);
        },
        onFailure: (value) async => failure = value,
      ),
      isTrue,
    );
    expect(await paused.future.timeout(const Duration(seconds: 5)), 5);
    for (var i = 0; i < 100 && runner.isActive('episode'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(failure?.action, DownloadFailureAction.reconcileRange);
    expect(failure?.resourceSize, 10);
    expect(await partial.readAsBytes(), [0, 1, 2, 3, 4]);
    expect(runner.isActive('episode'), isFalse);
  });

'''
text = Path(path).read_text()
text = text.replace(insert_after, extra + insert_after, 1)
Path(path).write_text(text)

print('Range reconciliation regression matrix added')
