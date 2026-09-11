from pathlib import Path

path = Path('lib/core/services/download_job_state.dart')
source = path.read_text()

old = '''  // Keep legacy userPaused=true as migration evidence too. A pause is safer to
  // preserve than to accidentally turn into network activity after relaunch.
  if (authoritativeUserPaused ||
      userPaused ||
      authoritativeState == DownloadJobState.pausedByUser ||
      authoritativeState == DownloadJobState.pausing) {
'''
new = '''  // Legacy userPaused is migration evidence only when no JobStore authority
  // exists (handled above). Once a durable logical state exists, replicas such
  // as metadata/plugin status may not override it.
  if (authoritativeUserPaused ||
      authoritativeState == DownloadJobState.pausedByUser ||
      authoritativeState == DownloadJobState.pausing) {
'''

if source.count(old) != 1:
    raise SystemExit(f'expected one authoritative pause block, found {source.count(old)}')
source = source.replace(old, new, 1)
path.write_text(source)
