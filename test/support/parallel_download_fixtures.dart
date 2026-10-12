import 'dart:io';

import 'package:background_downloader/background_downloader.dart';

/// Models a successful source probe in coordinator lifecycle tests. The actual
/// HTTP verifier's response/body validation is covered by gateway tests.
Future<({bool matches, String? validator})> verifiedSavedTestRange(
  DownloadTask task,
  File file,
  int bytes,
  int resourceSize,
) async {
  String? range;
  String? validator;
  for (final entry in task.headers.entries) {
    if (entry.key.toLowerCase() == 'range') range = entry.value;
    if (entry.key.toLowerCase() == 'if-range') validator = entry.value;
  }
  final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range ?? '');
  if (match == null) return (matches: false, validator: validator);
  final from = int.parse(match[1]!);
  final to = int.parse(match[2]!);
  return (
    matches: from >= 0 && to >= from && to < resourceSize &&
        bytes > 0 && bytes <= to - from + 1 &&
        await file.exists() && await file.length() == bytes,
    validator: validator,
  );
}

/// A test-only publisher for coordinator lifecycle tests. This does not prove
/// cross-process no-replace atomicity; the production Darwin helper tests do.
Future<bool> publishCompletedTestFile(
  File source,
  File target,
  int expectedBytes,
) async {
  if (await FileSystemEntity.type(target.path, followLinks: false) !=
          FileSystemEntityType.notFound ||
      !await source.exists() ||
      await source.length() != expectedBytes)
    return false;
  await source.rename(target.path);
  return true;
}
