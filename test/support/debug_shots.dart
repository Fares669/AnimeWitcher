import 'dart:io';

/// Where the widget tests drop their debug screenshots, or null when nobody
/// asked for any.
///
/// These shots are a development aid — render this screen so I can look at it
/// — and not assertions: nothing compares them against a baseline, and no test
/// fails if one changes. They were being written unconditionally to a
/// hard-coded `/opt/cursor/artifacts`, which meant every run of two dozen
/// widget tests paid for a full raster and PNG encode nobody had asked for,
/// and left the files outside the repository — on Windows, in `C:\opt`.
///
/// Set `ANIMEWITCHER_TEST_SHOTS` to a directory to collect them again:
///
/// ```
/// ANIMEWITCHER_TEST_SHOTS=build/shots flutter test
/// ```
Directory? debugShotDirectory() {
  final configured = Platform.environment['ANIMEWITCHER_TEST_SHOTS']?.trim();
  if (configured == null || configured.isEmpty) return null;
  return Directory(configured)..createSync(recursive: true);
}
