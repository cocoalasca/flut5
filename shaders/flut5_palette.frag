#version 460 core
// Snaps every pixel of an image to the nearest colour of a palette, judged
// in OKLab so "nearest" means nearest to the eye. Drawn 1:1 over the image
// as a paint shader — used on beginPixelate()'s one-pixel-per-block image.
// Every pixel comes out solid or empty: one at least half covered takes its
// palette colour in full, one below that is left empty.
//
// With u_write_indices set it writes which palette colour each pixel took
// instead, for flut5_palette_stroke.frag to outline: the palette index's low
// byte in red, its high byte in green, 1 in blue for a drawn pixel (0 for an
// empty one), and an opaque alpha so nothing is premultiplied away.
#include <flutter/runtime_effect.glsl>

precision highp float;

// Image size in pixels.
uniform vec2 u_size;
// Number of palette colours.
uniform float u_count;
// 1 to write palette indices, 0 to write colours.
uniform float u_write_indices;
uniform sampler2D u_image;
// The palette, u_count × 3 pixels: one column per colour, its fill in the
// top row (the rows below are for flut5_palette_stroke.frag).
uniform sampler2D u_palette;

const float kPaletteRows = 3.0;
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

void main() {
  vec4 pixel = texture(u_image, FlutterFragCoord().xy / u_size);
  if (pixel.a < kMinCoverage) {
    // Zero in blue marks the block empty in the index output.
    frag_color = u_write_indices > 0.5 ? vec4(0.0, 0.0, 0.0, 1.0) : vec4(0.0);
    return;
  }
  vec3 target = oklab(unpremultiply(pixel));
  float best = 1e20;
  float pickIndex = 0.0;
  vec4 pick = vec4(0.0);
  for (int i = 0; i < 4096; i++) {
    if (float(i) >= u_count) {
      break;
    }
    vec2 fillTexel = vec2((float(i) + 0.5) / u_count, 0.5 / kPaletteRows);
    vec4 entry = texture(u_palette, fillTexel);
    vec3 rgb = unpremultiply(entry);
    vec3 d = oklab(rgb) - target;
    float distance = dot(d, d);
    if (distance < best) {
      best = distance;
      pickIndex = float(i);
      pick = vec4(rgb, entry.a);
    }
  }
  if (u_write_indices > 0.5) {
    float highByte = floor(pickIndex / 256.0);
    float lowByte = pickIndex - highByte * 256.0;
    frag_color = vec4(lowByte / 255.0, highByte / 255.0, 1.0, 1.0);
    return;
  }
  // Drawn in full; only a translucent palette colour thins it.
  frag_color = vec4(pick.rgb * pick.a, pick.a);
}
