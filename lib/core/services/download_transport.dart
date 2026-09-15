import 'package:background_downloader/background_downloader.dart';

import 'background_downloader_transport.dart';
export 'background_downloader_transport.dart';

/// Compatibility classifier for the still-legacy single-task call sites.
/// New executor code should use [isBackgroundDownloaderTransportTask], which
/// also accepts logical [ParallelDownloadTask] instances.
bool isNativeSingleDownloadTask(Task task) =>
    task is DownloadTask && task is! ParallelDownloadTask;

/// Compatibility name retained while DownloadService call sites migrate to the
/// generalized executor. The implementation now lives exclusively in
/// [BackgroundDownloaderTransport].
@Deprecated('Use BackgroundDownloaderTransport')
class NativeSingleDownloadTransport extends BackgroundDownloaderTransport {
  NativeSingleDownloadTransport({FileDownloader? downloader})
    : super(downloader: downloader);
}
