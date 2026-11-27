# AnimeWitcher memory and CPU check on Windows

The goal is less RAM and unnecessary CPU work, not a smaller installer. The
benchmark separates initial load, idle Home, and three repeated Details-to-Home
trips. It follows one AnimeWitcher PID from launch; it does not infer a leak or
measure the whole Windows process group.

## Choose comparable builds and workload

- For the original focused pass, reference A is AnimeWitcher PR #282 at
  `233cc91dbf7423512c4bca9866ae26359ffc2077`. If assessing a public or preview
  installation, identify that build separately rather than substituting the PR
  as the installed build. A version string alone is not sufficient.
- Build A and candidate B from separate clean checkouts with the same Flutter
  version, dependency lockfile, native libraries, defines, architecture and
  build mode. Preserve the complete output directory of each
  `flutter build windows --release` (or `--profile` for both). Record the two
  source SHAs and build setup. The collector fingerprints the executable
  and `data/app.so`; it does not fingerprint every DLL, asset, or setting.
- Use the same laptop, selected monitor/DPI, window size, power mode, artwork
  quality, Home sections and title. Keep other workloads steady, leave
  playback/downloads idle, and use a local fixture or matching prepared cache
  where possible. Prime the same Home and Details before process-cold runs.
  This is not an OS-cold/cache-cleared experiment. Don't delete an installed
  app's data or reset a personal profile for the test.
- Place the PowerShell console and app side by side so the same transitions
  can be marked consistently. Close the app normally between trials. Don't
  add extra navigation or scroll during the idle/settle periods.

## Capture and compare

Run from a terminal on Windows, not the PowerShell ISE. Point at the complete
bundle's `animewitcher.exe`; the collector starts it and asks for Enter when
Home is usable, then once after each Details-to-Home loop. Wait for the agreed
Details readiness signal (for example, title art and episode list displayed) and
use the same title each loop. Once prompted, return to Home and mark promptly.
It neither edits preferences nor closes the app.

```powershell
.\scripts\measure_windows_memory.ps1 -AppExe C:\bench\A\animewitcher.exe -OutputDirectory C:\bench\a1 -Variant A -Revision <A-source-SHA> -ArtworkQuality standard -BuildMode release
```

Replace the angle-bracket placeholder with the actual 40-character SHA.
Collect A/A runs first as a noise check; then collect at least three matched A/B
pairs, alternating which build goes first. Use a new output directory every
time. Run the comparison in Python 3.10+ from the repository root; pass the A
directory first in each pair regardless of chronological launch order.

```powershell
python scripts/compare_windows_memory.py --mode aa --pair C:\bench\a1 C:\bench\a2
python scripts/compare_windows_memory.py --mode build --pair C:\bench\a3 C:\bench\b1 --pair C:\bench\a4 C:\bench\b2 --pair C:\bench\a5 C:\bench\b3
```

For an artwork-only comparison, use the **same** exact binary and source
revision, set the app preference yourself, restart between runs, and pass
`--mode artwork` with the standard and high capture directories. This is not a
comparison of cache sizes alone. At the pinned reference, both desktop artwork
settings have a 320 MiB configured cache ceiling, but decode dimensions and
eligible poster decode scheduling can differ.

Interpret the readings independently:

- **Working set:** resident process pages, including possibly shared pages.
  Its sampled peak can miss brief spikes. Task Manager may display a private
  working set or a process group instead, so its number need not match.
- **Private bytes:** allocation private to the process, not resident RAM.
  Report its settled change separately. Child/helper processes, separate
  GPU allocations, and end-to-end responsiveness are separate measurements.
- **CPU:** delta of cumulative process CPU time between first/last samples
  within each phase; percentage is relative to one logical core and can
  exceed 100%. Ignore or repeat pairs with long scheduling gaps, obvious
  background interference, different navigation timings or failed content.
- The report includes peak, sample gaps, last-window medians (10 s at most)
  and each Details loop's settled change from initial idle Home. Startup
  includes operator reaction time; inspect repeated values, not one number.
  Compare A/B deltas against A/A variation and retain per-pair outcomes when
  medians disagree or speed/memory trade off. Repeated growth is a lead,
  not proof of a leak, and a Linux comparison is not a Windows measurement.

See Microsoft's [.NET working-set](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.workingset64)
and [private memory](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.privatememorysize64)
definitions. The sampling output is local `run.json` plus `samples.csv`.
It contains counters, timestamps, and build fingerprints, not page content,
stream URLs or account data.

## Attribute Dart work with the Fast Anything fork

Use Fares669/fast-anything `feat/dart-flutter` pinned at
[`3a175d9cdb0b73b4eb4d07ad6c0baf3dc247a9fe`](https://github.com/Fares669/fast-anything/blob/3a175d9cdb0b73b4eb4d07ad6c0baf3dc247a9fe/docs/dart.md)
rather than assuming upstream has the same Dart adapter. Run on a disposable
checkout with pub dependencies resolved. In a **separate profile run**, start
Flutter with its authenticated loopback VM service and a private service file;
then attach the pinned scanner from the app checkout, matching the workload
being investigated:

```powershell
flutter run -d windows --profile --vmservice-out-file C:\bench\private\vm-service.txt
fast-anything scan --vm-service-file C:\bench\private\vm-service.txt --duration 60 -- flutter run --profile -t lib/main.dart
```

Collect idle and active runs separately and keep each raw result before the
next scan overwrites project scan state. The service file can carry an auth
token; don't share it, publish it, or disable authentication. Dart samples
can locate repeated app work but do not measure native image buffers, GPU
memory, or per-function RAM use. A release process A/B (above) answers whether
the change improves the footprint; a scan answers a different question
about where Dart CPU time is spent. Flutter scan results are analysis-only:
don't automatically port hot functions to Rust.

## Tool verification

```console
python scripts/test_compare_windows_memory.py
```

Fixture tests validate metric separation, matched comparisons and rejection of
incomplete/inconsistent logs. A Linux synthetic smoke can validate collector
phase sequencing, but Windows capture and actual device effects must be
verified on Windows.
