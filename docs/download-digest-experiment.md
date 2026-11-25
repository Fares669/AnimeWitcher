# Download publication digest (experimental)

AnimeWitcher's parallel download coordinator stages completed ranges, flushes the
staging file, and computes its SHA-256 before persisting the ready-to-publish
checkpoint. A digest mismatch still blocks publication and recovery. This
experiment replaces only the complete-file digest, not range handling,
storage checks, cancellation, checkpoint format, or publication.

The default remains Dart's streaming `package:crypto` implementation. The
coordinator runs this digest in a worker isolate rather than doing the SHA-256
work on the caller isolate. If the runtime cannot start a worker, it uses the
original streaming path on the caller.
On an **opt-in Linux x64 host and target**, the build can bundle a pinned
RustCrypto SHA-256 library. The file is still streamed in bounded chunks. The
Rust call runs in a worker isolate, passes no episode buffer through FFI, and
returns the same lowercase SHA-256. A missing asset, an unsupported target,
or a native read failure uses the existing Dart implementation. The fallback
still reports ordinary Dart file errors.

## Try it on Linux x64

Install a Rust toolchain with the `x86_64-unknown-linux-gnu` target, Cargo, and
a working Linux linker. In an experimental checkout, append this root section
to `pubspec.yaml` (do not add another section if it already has `hooks`):

```yaml
hooks:
  user_defines:
    animewitcher:
      rust_download_sha256: true
```

Run the normal Flutter command with
`--dart-define=ANIMEWITCHER_RUST_DOWNLOAD_SHA256=true`. Remove that flag
to use Dart immediately on the next build, or remove the YAML section to
avoid building/bundling Rust entirely. Other platform builds do not compile
this library. Cargo builds the pinned `Cargo.lock` with `--locked`; it does
not install the Rust toolchain. With a populated Cargo cache you can set
`CARGO_NET_OFFLINE=true`.

To check the actual packaged symbol and hash parity, set the YAML opt-in and
run:

```sh
flutter test test/core/utils/download_file_digest_test.dart \
  --dart-define=ANIMEWITCHER_RUST_DOWNLOAD_SHA256=true \
  --dart-define=ANIMEWITCHER_EXPECT_RUST_DOWNLOAD_SHA256=true
cargo test --locked --manifest-path native/download_sha256/Cargo.toml
```

Use local synthetic data for comparisons. The app's `assembly.begin` and
`assembly.complete` diagnostics delimit the staging, digest and publication
path. Network speeds, cold disk reads, thermal behavior, and Android/iOS
background downloads are not represented by Linux loopback measurements.

## Measurements

A 128 MiB generated file was hashed with the existing Dart streaming digest
and the Rust digest on a fresh Dart worker, in alternating order after
warm-up. Both used AOT on Linux x64 and returned identical hashes. Six measured
runs per implementation: about 1.38 s Dart vs 92 ms Rust per hash (medians).
This is the digest alone, not the time to download a whole episode.

A local HTTP range server also drove the real coordinator with a 128 MiB
fixture. The five measured baseline runs had median 2.72 s for assembly,
including 2.01 s for digest, 0.68 s for copy and flush, and 26 ms for final
rename/cleanup. The opt-in asset took the actual native path and published
identical bytes in the completed coordinator runs. Concurrent host load
made end-to-end wall time unstable, so these runs do not establish an overall
download speedup. No real media service or account credentials were used.

A separate paired 64 MiB loopback run alternated both implementations in the
same Flutter test process. After one warm-up pair, across three measured
pairs, median assembly was **1.52 s with Dart and 0.61 s with Rust**; the
digest phase was 977 ms and 55 ms respectively. All runs published identical
bytes, wrote the same independent checkpoint digest, and verified which
implementation actually ran. The download phase itself did not improve.
This is Linux x64 loopback evidence using the app's durable coordinator
directly. In the shipping app, range-supported episode downloads on iOS use
that coordinator; other platforms use the download package's transport.
The fixture does not imply that a normal Linux download uses this Rust asset,
and the timings are not mobile or CDN measurements.

For responsiveness we also compared the two Dart scheduling paths using the
same 64 MiB coordinator fixture, four runs per path. The median of the
per-run 95th-percentile gaps in a 16 ms main-isolate timer was 16.9 ms during
the digest on the caller and 16.1 ms on the digest worker. No digest-phase gap
exceeded 50 ms in either setup. This tests event-loop scheduling, not rendered
frames; it did not reproduce a phone UI freeze. The file contents, publication
hash, and recovery checks are unchanged.
