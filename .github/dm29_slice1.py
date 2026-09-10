from pathlib import Path
import re

service_path = Path('lib/core/services/download_service.dart')
plan_path = Path('DOWNLOAD_MANAGER_PLAN.md')
test_path = Path('test/core/services/download_durable_byte_provenance_guard_test.dart')

service = service_path.read_text()
plan = plan_path.read_text()

# One startup/reattach path synthesizes bytes into a local before checkpointing.
local_pattern = re.compile(
    r"\n\s{6}final durableBytes = totalSize > 0 && progress > 0\n"
    r"\s{10}\? \(totalSize \* progress\)\.floor\(\)\n"
    r"\s{10}: 0;\n"
)
service, local_count = local_pattern.subn('\n', service)
if local_count != 1:
    raise SystemExit(f'expected one local synthetic-byte calculation, found {local_count}')

# Remove lifecycle checkpoint arguments derived only from presentation progress.
direct_pattern = re.compile(
    r"\n(?P<indent>\s*)durableBytes: totalSize > 0 && progress > 0\n"
    r"(?P=indent)    \? \(totalSize \* progress\)\.floor\(\)\n"
    r"(?P=indent)    : 0,"
)
service, direct_count = direct_pattern.subn('', service)
if direct_count != 4:
    raise SystemExit(f'expected four direct synthetic durableBytes writes, found {direct_count}')

# A failed resume must use only the exact visible partial-byte observation.
saved_old = """            durableBytes: saved.totalSize > 0 && saved.progress > 0
                ? (saved.totalSize * saved.progress).floor()
                : saved.partialBytes,
"""
saved_new = """            durableBytes: saved.partialBytes,
"""
if service.count(saved_old) != 1:
    raise SystemExit(f'expected one failed-resume synthetic write, found {service.count(saved_old)}')
service = service.replace(saved_old, saved_new, 1)

# Startup attachment no longer has a local durableBytes variable, so remove its argument.
if '        durableBytes: durableBytes,\n        expectedBytes: totalSize,' not in service:
    raise SystemExit('startup attachment durableBytes argument not found')
service = service.replace(
    '        durableBytes: durableBytes,\n        expectedBytes: totalSize,',
    '        expectedBytes: totalSize,',
    1,
)

# Guard against reintroducing percentage-derived authoritative bytes in this service.
if '(totalSize * progress).floor()' in service:
    raise SystemExit('percentage-derived totalSize/progress bytes still present')
if '(saved.totalSize * saved.progress).floor()' in service:
    raise SystemExit('percentage-derived saved progress bytes still present')

service_path.write_text(service)

if test_path.exists():
    raise SystemExit('DM-29 guard test already exists')
test_path.write_text("""import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lifecycle checkpoints never turn percentage into durable byte truth', () {
    final source = File(
      'lib/core/services/download_service.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('(totalSize * progress).floor()')));
    expect(source, isNot(contains('(saved.totalSize * saved.progress).floor()')));
    expect(
      source,
      isNot(contains('durableBytes: totalSize > 0 && progress > 0')),
    );
  });
}
""")

anchor = """  - **Dependencies:** DM-19 defines native ownership/evidence quality.
"""
progress = """  - **Implementation status (2026-09-11):** First correctness slice removes percentage-derived JobStore byte writes from startup attachment, interruption, running, pause, and failed-resume lifecycle boundaries. Status/progress may still be projected to UI/metadata, but JobStore now either preserves its previous byte evidence or receives the exact visible `partialBytes` observation on failed resume. A regression guard rejects reintroduction of these `progress * totalSize` durable writes.
  - **Confirmed root cause so far:** lifecycle code reused UI/plugin percentage as if it were a durable-byte measurement; because JobStore is monotonic, one synthetic high-water mark could survive after the underlying native temp bytes disappeared and poison later recovery.
  - **Remaining before [x]:** add persisted byte-provenance semantics to DownloadJobStore and migrate old records; convert multipart manifest to a new schema with exact per-part durable-byte fields rather than `credibleProgress` as authority; audit native/Range checkpoint sources and accept them only when their durability contract is explicit; add migration/crash/0.999/native-temp-loss tests described above.
"""
# Add status only to DM-29's dependency anchor (first matching anchor after DM-29 heading).
dm29 = plan.find('- [ ] **DM-29')
if dm29 < 0:
    raise SystemExit('DM-29 heading not found or already complete')
idx = plan.find(anchor, dm29)
if idx < 0:
    raise SystemExit('DM-29 dependency anchor not found')
insert_at = idx + len(anchor)
if 'First correctness slice removes percentage-derived JobStore byte writes' in plan:
    raise SystemExit('DM-29 slice already documented')
plan = plan[:insert_at] + progress + plan[insert_at:]
plan_path.write_text(plan)
