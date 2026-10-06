#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uMaxSigma;
uniform float uFalloff;
uniform float uAxis;
uniform vec2 uRegionOriginPx;
uniform vec2 uRegionSizePx;
uniform sampler2D uTexture;

out vec4 fragColor;

const int kHalf = 12;

void main() {
  vec2 safeRegionSize = max(uRegionSizePx, vec2(1.0));
  vec2 region = clamp(
    (FlutterFragCoord().xy - uRegionOriginPx) / safeRegionSize,
    0.0,
    1.0
  );

  float sigma = uMaxSigma * pow(max(0.0, 1.0 - region.y), uFalloff);
  vec2 uv = FlutterFragCoord().xy / uSize;

  if (sigma < 0.35) {
    fragColor = texture(uTexture, uv);
    return;
  }

  vec2 axis = uAxis < 0.5
      ? vec2(1.0 / uSize.x, 0.0)
      : vec2(0.0, 1.0 / uSize.y);

  float stride = max(1.0, 3.0 * sigma / float(kHalf));
  float inv2SigmaSquared = 1.0 / (2.0 * sigma * sigma);
  float ratio = exp(-stride * stride * inv2SigmaSquared);
  float ratioStep = ratio * ratio;

  vec4 color = texture(uTexture, uv);
  float totalWeight = 1.0;
  float weight = 1.0;

  for (int i = 1; i <= kHalf; i++) {
    weight *= ratio;
    ratio *= ratioStep;

    float distancePx = float(i) * stride;
    vec2 delta = axis * distancePx;
    vec2 plus = uv + delta;
    vec2 minus = uv - delta;

    float plusValid =
        step(0.0, plus.x) * step(plus.x, 1.0) *
        step(0.0, plus.y) * step(plus.y, 1.0);
    float minusValid =
        step(0.0, minus.x) * step(minus.x, 1.0) *
        step(0.0, minus.y) * step(minus.y, 1.0);

    color += texture(uTexture, clamp(plus, 0.0, 1.0)) * weight * plusValid;
    color += texture(uTexture, clamp(minus, 0.0, 1.0)) * weight * minusValid;
    totalWeight += weight * (plusValid + minusValid);
  }

  fragColor = color / totalWeight;
}
