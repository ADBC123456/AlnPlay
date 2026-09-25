// Independent Flutter implementation of edge-normal RGB backdrop sampling.
// Optical approach: https://github.com/zsio/liquid-glass (src/glass.ts).
// No DOM, SVG filter, generated texture or upstream source is bundled.
#version 460 core
#include <flutter/runtime_effect.glsl>

// ImageFilter.shader supplies the first vec2 and sampler automatically.
uniform vec2 uTextureSize;
uniform vec2 uLogicalSize;
uniform float uDisplacementScale;
uniform float uAberrationIntensity;
uniform vec2 uOrigin;
uniform vec2 uViewportSize;
uniform float uSaturation;
uniform float uElasticity;
uniform float uPressure;
uniform sampler2D uBackdrop;
out vec4 fragColor;

vec4 sampleBackdrop(vec2 uv) {
  // Keep the optical sampling inside the Dock's own surface. Without this
  // bound, edge refraction pulls pixels from the page outside the Dock and
  // makes the surrounding background look liquidized too.
  vec2 texel = 0.5 / uTextureSize;
  vec2 surfaceMin = max(texel, uOrigin / uViewportSize);
  vec2 surfaceMax = min(1.0 - texel, (uOrigin + uLogicalSize) / uViewportSize);
  uv = clamp(uv, surfaceMin, surfaceMax);
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

vec3 saturate(vec3 color, float amount) {
  float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
  return mix(vec3(luminance), color, amount);
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
    vec4 center = sampleBackdrop(uv);
    fragColor = vec4(saturate(center.rgb, max(uSaturation, 100.0) / 100.0), center.a);
    return;
  }
  float edge = pow(1.0 - clamp(depth / bevel, 0.0, 1.0), 1.6);
  float incident = 1.3 * edge;
  // SVG's displacementScale is measured in CSS pixels.  A direct 200 px
  // offset would jump outside a 64 px dock, so convert it to a controlled
  // optical thickness while preserving the same public control value.
  float displacementPixels = clamp(uDisplacementScale * 0.04, 0.0, 14.0);
  displacementPixels *= 1.0 + uPressure * (0.35 + uElasticity * 0.65);
  float thickness = displacementPixels * (0.75 + 0.25 * abs(normal.x));
  vec2 direction = normal * thickness / uViewportSize;
  float separation = 0.03 * clamp(uAberrationIntensity / 9.0, 0.0, 2.0);
  float softEdge = 0.65 * edge;
  // Blue's effective IOR is higher, so its inward displacement is greatest.
  // All channels share the same normal and converge in the planar interior.
  vec4 red = sampleSoft(uv - direction * bending(incident, 1.46 - separation), softEdge);
  vec4 green = sampleSoft(uv - direction * bending(incident, 1.46), softEdge);
  vec4 blue = sampleSoft(uv - direction * bending(incident, 1.46 + separation), softEdge);
  float alpha = max(red.a, max(green.a, blue.a));
  vec3 color = min(vec3(red.r, green.g, blue.b), vec3(alpha));
  fragColor = vec4(saturate(color, max(uSaturation, 100.0) / 100.0), alpha);
}
