from pathlib import Path

p = Path('DOWNLOAD_MANAGER_PLAN.md')
s = p.read_text()
marker = '- [ ] **DM-06 — Strengthen resource identity and final completion verification**'
done = marker.replace('[ ]', '[x]')
if marker in s:
    s = s.replace(marker, done, 1)
    start = s.find(done)
    dep = s.find('  - **Dependencies:**', start)
    if dep < 0:
        raise SystemExit('DM-06 dependency line missing')
    end = s.find('\n', dep)
    notes = '''\n  - **Implementation notes (2026-09-11):** Resource identity now separates observed local bytes, independently expected resource bytes, stable validator evidence and volatile delivery URL. Fresh/range jobs persist strong ETag/Last-Modified/expected-size fingerprints when available; exact-size recovery, native completion and Range reconciliation require independent size plus stable-validator or byte-prefix proof. Source refresh permits signed URL rotation only when the stable fingerprint remains compatible.\n  - **Confirmed root cause:** completion paths could promote the file being verified into their own expected size and several resume/refresh paths persisted only URL+size, so a truncated or same-size replaced resource could satisfy size-only completion without durable identity proof.\n  - **Verification passed:** RED→GREEN service guards, same-size changed-resource rejection, signed-URL rotation acceptance, validator-free prefix proof, weak-ETag rejection, source-refresh integrity/checkpoint tests, recovery/durable-byte regressions, DM-05 authority and DM-24 logical-identity regressions, and analyzer.\n'''
    s = s[:end] + notes + s[end:]
    p.write_text(s)
elif done not in s:
    raise SystemExit('DM-06 checklist marker missing')
