# Pinned libmpv v0.41.0 target headers

These files are exact copies from `mpv-player/mpv` tag `v0.41.0`
under `include/mpv/`.

| File | Upstream Git blob SHA |
| --- | --- |
| `client.h` | `85cff63bd5d20797ca622834fd904d506d0d4fd8` |
| `render.h` | `99aadeb5d837dd47a8a170ae55672cf46ec5f4c4` |
| `render_gl.h` | `aa2719d5c4ebfa1ecaee469b563d138e10b1df4e` |
| `stream_cb.h` | `9ae6f31a16847d9a695886a78bc1b7a2c9942a27` |

These are **target headers only** until the Apple runtime is upgraded.
The current Apple media-kit runtime still comes from
`libmpv-darwin-build v0.6.0` / mpv `v0.36.0`, so the build must keep
using the existing v0.36 headers until runtime/header alignment is
switched atomically in MPV-04.

Verify integrity with:

```sh
python3 scripts/verify_mpv_integration.py --require-target-headers
```
