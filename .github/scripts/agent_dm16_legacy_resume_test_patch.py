from pathlib import Path

path = Path('test/core/utils/download_resume_test.dart')
source = path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global source
    if new in source:
        return
    count = source.count(old)
    if count != 1:
        raise SystemExit(f'{label} anchor mismatch: {count}')
    source = source.replace(old, new, 1)

replace_once(
    """  test('does not restart from zero when saved progress exists', () async {
    var restartCalls = 0;

    final result = await resumeOrRestartDownload(
      canResume: () async => false,
      resume: () async => false,
      restart: () async {
        restartCalls++;
        return true;
      },
      savedProgress: 0.42,
    );

    expect(result, isFalse);
    expect(restartCalls, 0);
  });
""",
    """  test('historical saved progress alone does not block zero restart', () async {
    var restartCalls = 0;

    final result = await resumeOrRestartDownload(
      canResume: () async => false,
      resume: () async => false,
      restart: () async {
        restartCalls++;
        return true;
      },
      savedProgress: 0.42,
    );

    expect(result, isTrue);
    expect(restartCalls, 1);
  });
""",
    'resumeOrRestart historical-progress expectation',
)

replace_once(
    """    expect(
      chooseDownloadResumeStrategy(
        canNativeResume: false,
        existingPartialBytes: 0,
        expectedBytes: 100,
        savedProgress: 0.4,
      ),
      DownloadResumeStrategy.partialFile,
    );
""",
    """    expect(
      chooseDownloadResumeStrategy(
        canNativeResume: false,
        existingPartialBytes: 0,
        expectedBytes: 100,
        savedProgress: 0.4,
      ),
      DownloadResumeStrategy.restartFromZero,
    );
""",
    'strategy historical-progress expectation',
)

replace_once(
    """    expect(
      shouldRestartDownloadFromZero(
        existingPartialBytes: 0,
        expectedBytes: 100,
        savedProgress: 0.25,
      ),
      isFalse,
    );
""",
    """    expect(
      shouldRestartDownloadFromZero(
        existingPartialBytes: 0,
        expectedBytes: 100,
        savedProgress: 0.25,
      ),
      isTrue,
    );
""",
    'zero-restart historical-progress expectation',
)

path.write_text(source)
