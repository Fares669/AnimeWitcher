import os
from pathlib import Path

path = Path('docs/superpowers/plans/2026-09-15-background-downloader-authority.md')
text = path.read_text()

constraint = '- Target the currently pinned `background_downloader ^9.6.1` public contract first; no blind dependency upgrade.\n'
plugin_first = constraint + '- For plugin-owned tasks, use `background_downloader 9.6.1` public `Transfer` / `Transfers` / `FileDownloader` lifecycle APIs first. New AnimeWitcher transport/retry/chunk logic requires a documented public-API gap; app-owned code should otherwise be limited to logical policy, resource/signed-URL integrity, and legacy migration.\n'
if plugin_first not in text:
    if text.count(constraint) != 1:
        raise SystemExit('global constraint anchor missing')
    text = text.replace(constraint, plugin_first, 1)


def mark_section(title: str, next_title: str, evidence: str) -> None:
    global text
    start = text.index(title)
    end = text.index(next_title, start)
    section = text[start:end]
    section = section.replace('- [ ] **Step', '- [x] **Step')
    if evidence not in section:
        split = section.rfind('\n---\n')
        if split < 0:
            raise SystemExit(f'section separator missing for {title}')
        section = section[:split] + '\n' + evidence + '\n' + section[split:]
    text = text[:start] + section + text[end:]

mark_section(
    '### Task 20: Keep logical expected size stable across plugin chunk telemetry and pause',
    '### Task 21: Resume plugin-parallel downloads through the same logical parent',
    'Evidence: RED regressions reproduced the `353053603 -> 110329255` shrink; commits `877f89bbb2ff2597a3937fb565b15c900a54dce4` and `6ed7d33764421ad51e680fa90e146892c92cd5c8` passed lifecycle/resource/telemetry suites and analyzer.',
)
mark_section(
    '### Task 22: Route cancel and system-cancel by executor ownership, not task shape',
    '### Task 23: Prove kill/relaunch and background survival without duplicate writers',
    'Evidence: RED run `35001961312` failed on task-shape routing; GREEN run `35002296470` passed focused cancel/ownership suites and analyzer; commit `98324a0b3800b6dece1e273b23c97e631ab0f272`.',
)

if '### Task 25: Keep signed-source refresh plugin-owned unless legacy ownership is proven' not in text:
    task25 = f'''\n---\n\n### Task 25: Keep signed-source refresh plugin-owned unless legacy ownership is proven\n\n**Files:**\n- Modify: `lib/core/services/download_service.dart`\n- Add: `test/core/services/download_plugin_source_refresh_routing_test.dart`\n- Modify: this plan.\n\n**Interfaces:**\n- Contract: `ParallelDownloadTask` shape never routes source replacement to `PersistentParallelDownload`; only a successfully restored legacy manifest/session does.\n- Contract: plugin-owned refresh updates the tracked `TaskRecord` and returns to `background_downloader` `Transfer` lifecycle APIs.\n- Contract: `background_downloader 9.6.1` parallel resume data embeds original child task descriptors and exposes no public child-source rewrite API. If those opaque bytes exist when the signed source changes, fail closed with `restartRequired` rather than migrate to legacy or silently discard bytes.\n\n- [x] **Step 1: Write RED plugin-first source-refresh regressions**\n\nRED run `35004189110`: 1 test passed and 3 failed on legacy-by-shape routing, parallel resumability probing, and opaque plugin resume handling.\n\n- [x] **Step 2: Verify the public plugin gap before adding app logic**\n\nReviewed `background_downloader 9.6.1`: `Transfer.resume()` owns resume/re-enqueue fallback; `ParallelDownloadTask` resumes stored child tasks from its `ResumeData`, and those stored child URLs are not replaceable through a public API. `TaskOptions.onTaskStart` on the parent is not propagated to restored chunk task descriptors.\n\n- [x] **Step 3: Implement minimal executor-aware refresh**\n\nProbe plugin resumability for parallel parents too. Use `_parallel.replaceSource` only after positive `_parallel.restore(task)` evidence. Otherwise update the plugin-tracked task record and return to the Transfer path. Opaque plugin-parallel resume data on an expired URL yields `restartRequired`.\n\n- [x] **Step 4: Run source-integrity, plugin-parallel, Transfer-authority, cancel-ownership tests and analyzer**\n\nGREEN one-shot run `{os.environ.get('GITHUB_RUN_ID', 'current')}` verifies the resulting head before commit.\n\n- [x] **Step 5: Commit**\n\n```bash\ngit commit -m "fix(downloads): keep source refresh on plugin executor"\n```\n\n'''
    marker = '\n## Plan self-review\n'
    if marker not in text:
        raise SystemExit('plan self-review marker missing')
    text = text.replace(marker, task25 + marker, 1)

path.write_text(text)
