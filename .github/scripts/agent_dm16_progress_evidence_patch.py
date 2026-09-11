from pathlib import Path

resume_path = Path('lib/core/utils/download_resume.dart')
resume = resume_path.read_text()
service_path = Path('lib/core/services/download_service.dart')
service = service_path.read_text()

old = '''  if (savedProgress > 0) return DownloadResumeStrategy.partialFile;\n  return DownloadResumeStrategy.restartFromZero;\n'''
new = '''  // Historical UI progress is not recoverable-byte evidence. If native resume\n  // data and durable local bytes are both absent, a clean restart is safe.\n  return DownloadResumeStrategy.restartFromZero;\n'''
if new not in resume:
    if resume.count(old) != 1:
        raise SystemExit(f'choose strategy progress anchor mismatch: {resume.count(old)}')
    resume = resume.replace(old, new, 1)

old = '''  if (existingPartialBytes > 0) return false;\n  if (savedProgress > 0) return false;\n  return true;\n'''
new = '''  if (existingPartialBytes > 0) return false;\n  // savedProgress is presentation history only and deliberately does not fence\n  // a zero-byte restart. Durable bytes/native ownership are checked elsewhere.\n  return true;\n'''
if new not in resume:
    if resume.count(old) != 1:
        raise SystemExit(f'restart progress anchor mismatch: {resume.count(old)}')
    resume = resume.replace(old, new, 1)

resume = resume.replace(
    '/// Prefer native resume data, then leftover bytes. Restart from 0 only when\n/// there is nothing to keep — never when pause/fail/kill left progress.\n',
    '/// Prefer native resume data, then durable leftover bytes. Historical UI\n/// progress never substitutes for recoverable bytes and cannot block restart.\n',
)
resume = resume.replace(
    '/// Resumes a paused/failed/killed download. Never starts over from byte 0\n/// when resume data, a partial file, or saved progress exists.\n',
    '/// Resumes a paused/failed/killed download. Native resume data and durable\n/// local bytes are recovery evidence; saved progress remains presentation only.\n',
)

old = '''      if (saved.progress > 0 || saved.partialBytes > 0) return false;\n      return _enqueueTransfer(task, saved.totalSize);\n'''
new = '''      // A historical percentage can survive after all multipart manifests and\n      // bytes are gone. Only actual surviving bytes may block a zero restart.\n      if (saved.partialBytes > 0) return false;\n      return _enqueueTransfer(task, saved.totalSize);\n'''
if new not in service:
    if service.count(old) != 1:
        raise SystemExit(f'parallel stale-progress anchor mismatch: {service.count(old)}')
    service = service.replace(old, new, 1)

resume_path.write_text(resume)
service_path.write_text(service)
