# Anime4K Apple SDR/HDR color acceptance

> **PENDING — physical color acceptance has not yet been recorded for the final merge candidate.**

This checklist is the physical-device acceptance gate for AKP-15 and is referenced by the final AKP-18 benchmark evidence. The primary target is iOS; use at least one supported physical iPhone/iPad. A physical Apple-silicon Mac comparison is useful additional coverage but is not a substitute for the iOS device gate.

## Automated safety contract

- The native media_kit destination remains `kCVPixelFormatType_32BGRA` after Anime4K publication.
- SDR Core Video color attachments remain associated with the media_kit-owned destination path.
- Dart reads mpv `video-params/gamma` and `video-params/colormatrix` before allowing Apple Metal.
- Only a known SDR transfer is allowed into the native Metal path.
- PQ, HLG, legacy HDR aliases, scRGB, and unknown/ambiguous transfer metadata fail closed to the exact resolved mpv GLSL pipeline.
- BT.2020 matrix/primaries alone never prove HDR or SDR.
- Opening a new episode with Anime4K already enabled waits through transient unknown metadata instead of requiring the user to reselect A/A+A manually.

## Physical-device comparison protocol

1. Record the physical device model, OS version, and **exact commit** under test.
2. Use one representative BT.709 SDR scene with gradients, skin tones, dark shadow detail, saturated line art, and near-white highlights.
3. Capture/reference the same timestamp and Anime4K mode/quality through the mpv GLSL path and the native Apple Metal path.
4. Reject the native path if there is visible gamma shift, crushed blacks, clipped highlights, hue/saturation drift, unexpected range conversion, or geometry/crop change.
5. Use representative PQ and/or HLG HDR content. Confirm native Metal does not own Anime4K for that content and that the exact resolved mpv GLSL fallback is active.
6. Compare HDR fallback against the normal mpv reference for highlight detail, shadow detail, tone mapping, and color. The fallback must not introduce a new tone-map or clipping difference.
7. Repeat the routing check after seek, pause/resume, stream/source change, rotation/resize, and app background/foreground so stale metadata cannot leave an invalid native route active.
8. Repeat on Apple-silicon macOS when practical before a macOS release, especially if player/render-path behavior changes independently from iOS.

## Acceptance record

- Physical Apple device: **PENDING**
- OS version: **PENDING**
- exact commit: **PENDING**
- SDR source / timestamps: **PENDING**
- SDR mode / quality: **PENDING**
- SDR native-vs-mpv visual result: **PENDING**
- HDR source / transfer metadata: **PENDING**
- HDR fallback route result: **PENDING**
- HDR visual/tone-mapping result: **PENDING**
- Lifecycle/routing stress result: **PENDING**
- Overall AKP-15 result: **PENDING**

Do not claim physical color acceptance until these records exist or the gate is explicitly waived for the merge.
