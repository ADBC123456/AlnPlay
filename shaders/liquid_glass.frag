// Local icon/text-atlas lens inspired by Kyant0/AndroidLiquidGlass.
// The live page backdrop remains a native BackdropFilter; this shader never
// samples the page or a platform/HDR video surface.
#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 uAtlasSize;
uniform vec2 uLensCenter;
uniform vec2 uLensSize;
uniform float uPressed;
uniform sampler2D uAtlas;
out vec4 fragColor;

float roundedBoxSdf(vec2 p, vec2 halfSize, float radius) {
  vec2 q = abs(p) - halfSize + radius;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

void main() {
  vec2 point = FlutterFragCoord().xy;
  vec2 halfSize = uLensSize * 0.5;
  float radius = min(halfSize.x, halfSize.y);
  vec2 fromCenter = point - uLensCenter;
  float distance = roundedBoxSdf(fromCenter, halfSize, radius);
  if (distance > 0.0) {
    fragColor = vec4(0.0);
    return;
  }

  float radial = clamp(
    length(fromCenter / max(halfSize, vec2(1.0))),
    0.0,
    1.0
  );
  float edge = smoothstep(0.18, 1.0, radial);
  vec2 normal = normalize(fromCenter + vec2(0.0001));
  float strength = mix(1.8, 4.2, edge) + uPressed * 1.2;
  vec2 displaced = point - normal * strength;
  vec2 uv = clamp(displaced / uAtlasSize, vec2(0.001), vec2(0.999));
  vec4 content = texture(uAtlas, uv);
  float highlight = smoothstep(-5.0, -0.3, distance) *
    (1.0 - smoothstep(-0.3, 0.0, distance));
  vec4 outputColor = content + vec4(vec3(highlight * 0.08), highlight * 0.08);
  fragColor = vec4(min(outputColor.rgb, vec3(outputColor.a)), outputColor.a);
}
