import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;

import 'background_downloader_transport.dart'
    show animeDownloadTransferHints, shouldUseUserInitiatedDownloadHint;
import 'download_parallel.dart';

/// Transport backend selected for one logical episode.
///
/// This policy is deliberately independent from platform I/O. Platform
/// acceptance for plugin-owned parallel execution is supplied by the caller
/// only after that platform's lifecycle matrix has passed.
enum DownloadExecutionBackend { pluginSingle, pluginParallel, legacyParallel }

/// Executor that owns control operations for an already-created logical task.
///
/// [ParallelDownloadTask] is only a task shape: both background_downloader and
/// AnimeWitcher's legacy multipart executor use it. A positive legacy manifest
/// query is therefore the only reason to route pause/cancel/source mutation to
/// the legacy coordinator. Query failure stays unknown and fails closed.
enum DownloadExecutorControlTarget { plugin, legacy, unknown }

DownloadExecutorControlTarget selectDownloadExecutorControlTarget({
  required bool isParallelTask,
  required bool legacyQuerySucceeded,
  required bool legacySessionExists,
}) {
  if (!isParallelTask) return DownloadExecutorControlTarget.plugin;
  if (!legacyQuerySucceeded) return DownloadExecutorControlTarget.unknown;
  return legacySessionExists
      ? DownloadExecutorControlTarget.legacy
      : DownloadExecutorControlTarget.plugin;
}

/// Android-specific executor and scheduler hints for one logical episode.
///
/// The backend decision remains single-writer safe, while UIDT priority is
/// independently gated by the notification preconditions required on Android.
class AndroidDownloadExecutionPolicy {
  const AndroidDownloadExecutionPolicy({
    required this.backend,
    required this.transferHints,
  });

  final DownloadExecutionBackend backend;
  final Set<TransferHint> transferHints;
}

/// Plans Android execution without performing platform I/O.
///
/// A denied/missing notification permission never requests
/// [TransferHint.userInitiated]; the task remains pause/resume capable and may
/// still carry [TransferHint.largeFile] so background_downloader can use its
/// normal resumable WorkManager path. Multipart selection stays behind the
/// independently proven plugin-parallel capability gate, and any durable legacy
/// multipart evidence wins over that gate.
AndroidDownloadExecutionPolicy planAndroidDownloadExecutionPolicy({
  required int connections,
  required bool pluginParallelAccepted,
  required bool legacySessionExists,
  required bool notificationsConfigured,
  required bool notificationPermissionGranted,
  required int expectedBytes,
}) {
  final backend = selectDownloadExecutionBackend(
    connections: connections,
    pluginParallelAccepted: pluginParallelAccepted,
    legacySessionExists: legacySessionExists,
  );
  final useUserInitiated = shouldUseUserInitiatedDownloadHint(
    isAndroid: true,
    notificationsConfigured: notificationsConfigured,
    notificationPermissionGranted: notificationPermissionGranted,
  );
  return AndroidDownloadExecutionPolicy(
    backend: backend,
    transferHints: animeDownloadTransferHints(
      expectedBytes: expectedBytes,
      useUserInitiated: useUserInitiated,
    ),
  );
}

/// Capability table for fresh plugin-owned parallel downloads.
///
/// Every platform stays fail-closed until its real-device lifecycle matrix is
/// accepted. Durable PR #231 manifests still win in
/// [selectDownloadExecutionBackend], so an existing legacy session never
/// changes executor mid-transfer. Enabling a platform here is the final step
/// after device acceptance, never a substitute for that acceptance.
bool pluginParallelAcceptedForPlatform(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.android ||
      TargetPlatform.fuchsia ||
      TargetPlatform.iOS ||
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => false,
    };

/// Allows a deliberately-built acceptance artifact to exercise plugin-owned
/// parallel transport without changing the production platform capability
/// table. Normal builds pass [acceptanceBuildOverride] as false and therefore
/// remain fail-closed until real-device acceptance is recorded.
bool pluginParallelAcceptedForBuild(
  TargetPlatform platform, {
  required bool acceptanceBuildOverride,
}) =>
    acceptanceBuildOverride || pluginParallelAcceptedForPlatform(platform);

/// Selects exactly one executor for a logical episode.
///
/// Existing legacy multipart sessions always stay on their original executor;
/// changing executor mid-session could create overlapping writers for the same
/// durable ranges. Fresh single-connection downloads use background_downloader
/// directly. Fresh multipart downloads move to background_downloader only after
/// the caller has enabled plugin parallel support for the current platform.
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