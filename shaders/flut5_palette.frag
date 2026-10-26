#version 460 core
// Snaps every pixel of an image to the nearest colour of a palette, judged
// in OKLab so "nearest" means nearest to the eye. Drawn 1:1 over the image
// as a paint shader — used on beginPixelate()'s one-pixel-per-block image.
#include <flutter/runtime_effect.glsl>

precision highp float;

// Image size in pixels.
uniform vec2 u_size;
// Number of palette colours.
uniform float u_count;
uniform sampler2D u_image;
// The palette, u_count × 1 pixels, one colour per pixel.
uniform sampler2D u_palette;

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
  if (pixel.a <= 0.0) {
    frag_color = vec4(0.0);
    return;
  }
  vec3 target = oklab(unpremultiply(pixel));
  float best = 1e20;
  vec4 pick = vec4(0.0);
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
      pick = vec4(rgb, entry.a);
    }
  }
  // The pixel keeps its coverage; a translucent palette colour thins it.
  float alpha = pixel.a * pick.a;
  frag_color = vec4(pick.rgb * alpha, alpha);
}
