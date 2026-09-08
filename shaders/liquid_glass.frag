// Original Flutter implementation inspired by the material treatment in
// Kyant0/AndroidLiquidGlass (https://github.com/Kyant0/AndroidLiquidGlass).
// No upstream shader or Kotlin implementation is copied or translated here.
#version 460 core
#include <flutter/runtime_effect.glsl>

// ImageFilter automatically binds input dimensions and the first sampler.
uniform vec2 uSize;
uniform float uPressed;
uniform sampler2D uBackdrop;
out vec4 fragColor;

vec4 sampleBackdrop(vec2 point) {
  vec2 uv = clamp(point / uSize, vec2(0.001), vec2(0.999));
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(uBackdrop, uv);
}

void main() {
  vec2 point = FlutterFragCoord().xy;
  // uSize describes the bound filter input, not the clipped Dock capsule.
  // Sampling by a fraction of uSize would therefore reach distant page text.
  // Keep diffusion within adjacent physical texels; the composed native
  // Gaussian filter supplies the broad, soft blur.
  float spread = 1.25 + 0.50 * uPressed;
  vec4 color = sampleBackdrop(point) * 0.44;
  color += sampleBackdrop(point + vec2(spread, 0.0)) * 0.14;
  color += sampleBackdrop(point - vec2(spread, 0.0)) * 0.14;
  color += sampleBackdrop(point + vec2(0.0, spread)) * 0.14;
  color += sampleBackdrop(point - vec2(0.0, spread)) * 0.14;
  fragColor = vec4(min(color.rgb, vec3(color.a)), color.a);
}
