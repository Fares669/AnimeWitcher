from pathlib import Path

path = Path('lib/core/utils/download_resume.dart')
text = path.read_text()

if 'enum DownloadSourceRefreshResumeAction' in text:
    raise SystemExit(0)

marker = '''enum DownloadResumeStrategy {
  /// OS/plugin resume data is present — continue the same native task.
  nativeResume,

  /// A leftover dest/temp file has bytes that should be appended to.
  partialFile,

  /// Nothing to keep; start the transfer from byte 0.
  restartFromZero,
}
'''

insert = marker + '''
/// Recovery action to use when a resumable task may need a refreshed source.
///
/// Native resume data can embed the old signed URL and is opaque to Dart. A
/// source replacement must therefore never silently discard opaque bytes. Only
/// a same-source native resume, a visible prefix, or multipart-owned child bytes
/// can be migrated automatically. Otherwise the caller must surface an explicit
/// restart-required outcome.
enum DownloadSourceRefreshResumeAction {
  nativeResume,
  visiblePrefix,
  multipartRefresh,
  restartFromZero,
  restartRequired,
}

DownloadSourceRefreshResumeAction planDownloadSourceRefreshResume({
  required bool sourceRefreshRequired,
  required bool canNativeResumeCurrentSource,
  required bool hasOpaqueNativeResume,
  required int visiblePartialBytes,
  required bool isMultipart,
}) {
  if (!sourceRefreshRequired && canNativeResumeCurrentSource) {
    return DownloadSourceRefreshResumeAction.nativeResume;
  }
  if (isMultipart) {
    return DownloadSourceRefreshResumeAction.multipartRefresh;
  }
  if (visiblePartialBytes > 0) {
    return DownloadSourceRefreshResumeAction.visiblePrefix;
  }
  if (hasOpaqueNativeResume) {
    return DownloadSourceRefreshResumeAction.restartRequired;
  }
  return DownloadSourceRefreshResumeAction.restartFromZero;
}
'''

if marker not in text:
    raise SystemExit('DownloadResumeStrategy marker not found')

path.write_text(text.replace(marker, insert, 1))
