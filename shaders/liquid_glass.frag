// Independent Flutter implementation of edge-normal RGB backdrop sampling.
// Optical approach: https://github.com/zsio/liquid-glass (src/glass.ts).
// No DOM, SVG filter, generated texture or upstream source is bundled.
#version 460 core
#include <flutter/runtime_effect.glsl>

// ImageFilter.shader supplies the first vec2 and sampler automatically.
uniform vec2 uTextureSize;
uniform vec2 uLogicalSize;
uniform float uDispersion;
uniform float uRefraction;
uniform vec2 uOrigin;
uniform vec2 uViewportSize;
uniform sampler2D uBackdrop;
out vec4 fragColor;

vec4 sampleBackdrop(vec2 uv) {
  uv = clamp(uv, 0.5 / uTextureSize, 1.0 - 0.5 / uTextureSize);
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(uBackdrop, uv);
}

vec4 sampleSoft(vec2 uv, float sigma) {
  vec2 spread = vec2(2.0 * sigma) / uViewportSize;
  return sampleBackdrop(uv) * 0.5 +
      (sampleBackdrop(uv + vec2(spread.x, 0.0)) +
       sampleBackdrop(uv - vec2(spread.x, 0.0)) +
       sampleBackdrop(uv + vec2(0.0, spread.y)) +
       sampleBackdrop(uv - vec2(0.0, spread.y))) * 0.125;
}

float bending(float incident, float ior) {
  // Snell's law at an air/glass interface; the bevel acts as a thin lens.
  return tan(incident - asin(sin(incident) / ior));
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uTextureSize;
  vec2 point = uv * uViewportSize - uOrigin - uLogicalSize * 0.5;
  float radius = min(uLogicalSize.x, uLogicalSize.y) * 0.5;
  vec2 straight = max(uLogicalSize * 0.5 - radius, vec2(0.0));
  vec2 axis = clamp(point, -straight, straight);
  vec2 fromAxis = point - axis;
  float depth = max(radius - length(fromAxis), 0.0);
  vec2 normal = fromAxis / max(length(fromAxis), 0.001);
  float bevel = min(12.0, radius * 0.45);
  if (depth >= bevel) {
    fragColor = sampleBackdrop(uv);
    return;
  }
  float edge = pow(1.0 - clamp(depth / bevel, 0.0, 1.0), 1.6);
  float incident = 1.3 * edge;
  float thickness = uRefraction * (0.75 + 0.25 * abs(normal.x));
  vec2 direction = normal * thickness / uViewportSize;
  float separation = 0.025 * uDispersion;
  float softEdge = 0.65 * edge;
  // Blue's effective IOR is higher, so its inward displacement is greatest.
  // All channels share the same normal and converge in the planar interior.
  vec4 red = sampleSoft(uv - direction * bending(incident, 1.46 - separation), softEdge);
  vec4 green = sampleSoft(uv - direction * bending(incident, 1.46), softEdge);
  vec4 blue = sampleSoft(uv - direction * bending(incident, 1.46 + separation), softEdge);
  float alpha = max(red.a, max(green.a, blue.a));
  fragColor = vec4(min(vec3(red.r, green.g, blue.b), vec3(alpha)), alpha);
}
