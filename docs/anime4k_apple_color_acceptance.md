# Anime4K Apple SDR/HDR color acceptance

This checklist is the physical-device acceptance gate for AKP-15 and the final benchmark evidence collected again in AKP-18.

## Automated safety contract

- The native media_kit destination remains `kCVPixelFormatType_32BGRA` after Anime4K publication.
- SDR Core Video color attachments (BT.709 primaries, transfer function, and matrix) remain attached to the same media_kit-owned destination buffer.
- Dart reads mpv `video-params/gamma` and `video-params/colormatrix` before allowing Apple Metal.
- Only a known SDR transfer is allowed into the native Metal path.
- PQ, HLG, legacy HDR aliases, scRGB, and unknown/ambiguous transfer metadata fail closed to the exact resolved mpv GLSL pipeline.
- BT.2020 matrix/primaries alone never prove HDR or SDR.

## Physical-device comparison protocol

Run on at least one supported iPhone/iPad and one Apple-silicon Mac before final performance sign-off.

1. Use one representative BT.709 SDR frame with gradients, skin tones, dark shadow detail, saturated line art, and near-white highlights.
2. Capture/reference the frame with the mpv GLSL Anime4K path, then compare the same timestamp/mode/quality through Apple Metal.
3. Reject the Metal path if there is visible gamma shift, crushed blacks, clipped highlights, hue/saturation drift, or unexpected range conversion.
4. Use representative PQ and HLG HDR clips. Confirm diagnostics report the mpv backend and that native Metal is not active for those clips.
5. Compare the HDR fallback against the normal mpv reference for highlight detail, shadow detail, and color. The fallback must not introduce a new tone-map or clipping difference.
6. Repeat after seek, pause/resume, stream/source change, rotation/resize, and app background/foreground so metadata changes cannot leave a stale Metal route active.

Record device model, OS version, clip/fixture identifier, Anime4K mode/quality, backend, and pass/fail notes with the AKP-18 benchmark evidence. Do not claim physical color acceptance until those records exist.
