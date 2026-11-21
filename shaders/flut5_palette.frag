#version 460 core
// Snaps every pixel of an image to the nearest colour of a palette, judged
// in OKLab so "nearest" means nearest to the eye. Drawn 1:1 over the image
// as a paint shader — used on beginPixelate()'s one-pixel-per-block image.
// Every pixel comes out solid or empty: one at least half covered takes its
// palette colour in full, one below that is left empty.
#include <flutter/runtime_effect.glsl>

precision highp float;

// Image size in pixels.
uniform vec2 u_size;
// Number of palette colours.
uniform float u_count;
uniform sampler2D u_image;
// The palette, u_count × 1 pixels, one colour per pixel.
uniform sampler2D u_palette;

// The least coverage a pixel needs to be drawn.
const float kMinCoverage = 0.5;

out vec4 frag_color;

vec3 toLinear(vec3 c) {
  return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}

// sRGB → OKLab (Björn Ottosson, 2020).
vec3 oklab(vec3 srgb) {
  vec3 c = toLinear(srgb);
  vec3 lms = vec3(
    dot(vec3(0.4122214708, 0.5363325363, 0.0514459929), c),
    dot(vec3(0.2119034982, 0.6806995451, 0.1073969566), c),
    dot(vec3(0.0883024619, 0.2817188376, 0.6299787005), c)
  );
  lms = pow(max(lms, vec3(0.0)), vec3(1.0 / 3.0));
  return vec3(
    dot(vec3(0.2104542553, 0.7936177850, -0.0040720468), lms),
    dot(vec3(1.9779984951, -2.4285922050, 0.4505937099), lms),
    dot(vec3(0.0259040371, 0.7827717662, -0.8086757660), lms)
  );
}

// Samples are premultiplied; colours are compared and returned straight.
vec3 unpremultiply(vec4 c) {
  return c.a > 0.0 ? c.rgb / c.a : vec3(0.0);
}

// The palette colour nearest [target], an OKLab colour: straight colour,
// its alpha in a.
vec4 nearestPaletteColour(vec3 target) {
  float best = 1e20;
  vec4 nearest = vec4(0.0);
  for (int i = 0; i < 4096; i++) {
    if (float(i) >= u_count) {
      break;
    }
    vec4 entry = texture(u_palette, vec2((float(i) + 0.5) / u_count, 0.5));
    vec3 rgb = unpremultiply(entry);
    vec3 d = oklab(rgb) - target;
    float distance = dot(d, d);
    if (distance < best) {
      best = distance;
      nearest = vec4(rgb, entry.a);
    }
  }
  return nearest;
}

// main() has a single exit: early returns next to texture samplers can crash
// the Direct3D shader compiler under ANGLE on Windows
// (https://github.com/flutter/flutter/issues/190809).
void main() {
  vec4 pixel = texture(u_image, FlutterFragCoord().xy / u_size);
  // Empty unless at least half covered.
  vec4 colour = vec4(0.0);
  if (pixel.a >= kMinCoverage) {
    vec4 nearest = nearestPaletteColour(oklab(unpremultiply(pixel)));
    // Drawn in full; only a translucent palette colour thins it.
    colour = vec4(nearest.rgb * nearest.a, nearest.a);
  }
  frag_color = colour;
}
