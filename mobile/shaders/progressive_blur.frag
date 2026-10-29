#version 460 core
// One pass of a separable gaussian blur whose strength fades out from the top edge, used as a backdrop filter.
// Apply it twice, horizontally and vertically, for a two dimensional blur.

#include <flutter/runtime_effect.glsl>

precision mediump float;

// Set by the engine to the size of the filter input
uniform vec2 uSize;
// (1, 0) for the horizontal pass, (0, 1) for the vertical pass
uniform vec2 uDirection;
// Blur sigma at the top edge, in physical pixels
uniform float uMaxSigma;
// Distance from the top edge at which the blur has faded out, in physical pixels
uniform float uBlurEnd;
// Set by the engine to the filter input
uniform sampler2D uTexture;

out vec4 fragColor;

// Samples on each side of the pixel, spread over three sigmas whatever the blur strength
const int kTaps = 12;

vec4 sampleInput(vec2 position) {
  vec2 uv = position / uSize;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(uTexture, uv);
}

void main() {
  vec2 position = FlutterFragCoord().xy;
  float sigma = uMaxSigma * smoothstep(0.0, 1.0, 1.0 - position.y / uBlurEnd);
  if (sigma < 0.3) {
    fragColor = sampleInput(position);
    return;
  }

  float spacing = sigma * 3.0 / float(kTaps);
  vec4 sum = vec4(0.0);
  float total = 0.0;
  for (int i = -kTaps; i <= kTaps; i++) {
    float offset = float(i) * spacing;
    float weight = exp(-0.5 * (offset * offset) / (sigma * sigma));
    sum += sampleInput(position + uDirection * offset) * weight;
    total += weight;
  }
  fragColor = sum / total;
}
