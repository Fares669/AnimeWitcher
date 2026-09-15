import 'package:background_downloader/background_downloader.dart';

import 'download_parallel.dart';

/// Transport backend selected for one logical episode.
///
/// This policy is deliberately independent from platform I/O. Platform
/// acceptance for plugin-owned parallel execution is supplied by the caller
/// only after that platform's lifecycle matrix has passed.
enum DownloadExecutionBackend {
  pluginSingle,
  pluginParallel,
  legacyParallel,
}

/// Selects exactly one executor for a logical episode.
///
/// Existing legacy multipart sessions always stay on their original executor;
/// changing executor mid-session could create overlapping writers for the same
/// durable ranges. Fresh single-connection downloads use background_downloader
/// directly. Fresh multipart downloads move to background_downloader only after
/// the caller has proven plugin parallel support for the current platform.
DownloadExecutionBackend selectDownloadExecutionBackend({
  required int connections,
  required bool pluginParallelAccepted,
  required bool legacySessionExists,
}) {
  if (legacySessionExists) return DownloadExecutionBackend.legacyParallel;
  if (connections <= 1) return DownloadExecutionBackend.pluginSingle;
  return pluginParallelAccepted
      ? DownloadExecutionBackend.pluginParallel
      : DownloadExecutionBackend.legacyParallel;
}

/// Builds the executor task for a fresh plugin-owned logical download.
///
/// Single-connection downloads keep their existing [DownloadTask] identity.
/// Multipart downloads are converted exactly once, preserving the logical
/// taskId and every option supported by [ParallelDownloadTask].
DownloadTask buildPluginTransportTask({
  required DownloadTask template,
  required int connections,
}) {
  return buildAdaptiveDownloadTask(template: template, parts: connections);
}
