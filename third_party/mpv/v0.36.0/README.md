# Pinned libmpv headers

These four headers come from `mpv-player/mpv` tag `v0.36.0`, the exact
version expected by `media_kit_video` 2.0.1. They are kept in the repository
so iOS builds do not depend on a GitHub archive download during `pod install`.

| File | Git blob SHA |
| --- | --- |
| `client.h` | `b9697eb7416ba3f85f4efcde0f540f4ddd171def` |
| `render.h` | `29f9b91e9625ad27733fee68002a8018673df0e1` |
| `render_gl.h` | `a2c31f0c725adb87dda538edbfc6247b175df19c` |
| `stream_cb.h` | `9d1c2cc8d307c62d1f394e8b1479eb86468c67af` |

The build script verifies every blob before copying it into the resolved Dart
package. The original mpv license notice is retained at the top of each file.
