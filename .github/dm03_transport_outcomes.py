from pathlib import Path

TRANSPORT = Path('lib/core/services/download_transport.dart')
PLAN = Path('DOWNLOAD_MANAGER_PLAN.md')
TEST = Path('test/core/services/download_transport_outcome_test.dart')

source = TRANSPORT.read_text()

anchor = '''enum DownloadCancelSettlement { canceled, alreadyGone, stillOwned, unknown }\n\n'''
insert = '''enum DownloadCancelSettlement { canceled, alreadyGone, stillOwned, unknown }\n\n/// Low-level result of issuing a non-terminal transport command. This is kept\n/// separate from DownloadService's logical/user-visible command outcome: an\n/// accepted executor command is not proof that the requested logical state has\n/// been durably reached.\nenum DownloadTransportCommandOutcome { accepted, rejected, unavailable }\n\nDownloadTransportCommandOutcome resolveDownloadTransportCommandOutcome({\n  required bool commandAccepted,\n  bool transportAvailable = true,\n}) {\n  if (!transportAvailable) return DownloadTransportCommandOutcome.unavailable;\n  return commandAccepted\n      ? DownloadTransportCommandOutcome.accepted\n      : DownloadTransportCommandOutcome.rejected;\n}\n\n'''
if anchor not in source:
    raise SystemExit('enum anchor missing')
source = source.replace(anchor, insert, 1)

iface = '''abstract interface class DownloadTransport {\n  bool owns(String taskId);\n  Future<bool> start(DownloadTask task);\n  Future<bool> pause(DownloadTask task);\n  Future<bool> resume(DownloadTask task);\n  Future<DownloadCancelSettlement> cancel(DownloadTask task);\n'''
iface_new = '''abstract interface class DownloadTransport {\n  bool owns(String taskId);\n\n  // Legacy bool commands stay temporarily available while DM-03 migrates all\n  // DownloadService/UI callers. New orchestration must consume the typed seam.\n  Future<bool> start(DownloadTask task);\n  Future<bool> pause(DownloadTask task);\n  Future<bool> resume(DownloadTask task);\n  Future<DownloadTransportCommandOutcome> startOutcome(DownloadTask task);\n  Future<DownloadTransportCommandOutcome> pauseOutcome(DownloadTask task);\n  Future<DownloadTransportCommandOutcome> resumeOutcome(DownloadTask task);\n  Future<DownloadCancelSettlement> cancel(DownloadTask task);\n'''
if iface not in source:
    raise SystemExit('interface anchor missing')
source = source.replace(iface, iface_new, 1)

cancel_anchor = '''  @override\n  Future<DownloadCancelSettlement> cancel(DownloadTask task) async {\n'''
wrappers = '''  @override\n  Future<DownloadTransportCommandOutcome> startOutcome(DownloadTask task) async {\n    if (!isNativeSingleDownloadTask(task)) {\n      return DownloadTransportCommandOutcome.unavailable;\n    }\n    return resolveDownloadTransportCommandOutcome(\n      commandAccepted: await start(task),\n    );\n  }\n\n  @override\n  Future<DownloadTransportCommandOutcome> pauseOutcome(DownloadTask task) async {\n    if (!isNativeSingleDownloadTask(task)) {\n      return DownloadTransportCommandOutcome.unavailable;\n    }\n    return resolveDownloadTransportCommandOutcome(\n      commandAccepted: await pause(task),\n    );\n  }\n\n  @override\n  Future<DownloadTransportCommandOutcome> resumeOutcome(DownloadTask task) async {\n    if (!isNativeSingleDownloadTask(task)) {\n      return DownloadTransportCommandOutcome.unavailable;\n    }\n    return resolveDownloadTransportCommandOutcome(\n      commandAccepted: await resume(task),\n    );\n  }\n\n'''
if cancel_anchor not in source:
    raise SystemExit('cancel method anchor missing')
source = source.replace(cancel_anchor, wrappers + cancel_anchor, 1)
TRANSPORT.write_text(source)

TEST.write_text(r'''import 'package:animewitcher/core/services/download_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveDownloadTransportCommandOutcome', () {
    test('accepted command remains distinct from logical success', () {
      expect(
        resolveDownloadTransportCommandOutcome(commandAccepted: true),
        DownloadTransportCommandOutcome.accepted,
      );
    });

    test('rejected command is explicit', () {
      expect(
        resolveDownloadTransportCommandOutcome(commandAccepted: false),
        DownloadTransportCommandOutcome.rejected,
      );
    });

    test('unavailable transport cannot masquerade as rejection', () {
      expect(
        resolveDownloadTransportCommandOutcome(
          commandAccepted: false,
          transportAvailable: false,
        ),
        DownloadTransportCommandOutcome.unavailable,
      );
    });
  });
}
''')

plan = PLAN.read_text()
dep = '  - **Dependencies:** DM-19, DM-21, DM-30; conservative outcomes can land earlier.\n'
note = '''  - **Progress (2026-09-11, partial):** Added a typed transport-command seam (`DownloadTransportCommandOutcome.accepted/rejected/unavailable`) plus typed `startOutcome/pauseOutcome/resumeOutcome` methods. Legacy bool transport methods are intentionally retained only as a compatibility bridge while the service/UI migration is completed; this prevents a flag-day API break while making new orchestration distinguish executor availability from command rejection.\n  - **Verification (partial):** pure outcome matrix test + native transport wrapper compilation + generated-source-aware analyzer. **Still required before `[x]`:** introduce the logical `DownloadCommandOutcome` at DownloadService, map start/attach/queue/already-complete/readiness/missing-state/ownership-settling/failure/terminal branches, migrate launcher/provider/UI callers, then add the full scenario matrix listed above.\n'''
if note not in plan:
    if dep not in plan:
        raise SystemExit('DM-03 dependency anchor missing')
    plan = plan.replace(dep, dep + note, 1)
PLAN.write_text(plan)
