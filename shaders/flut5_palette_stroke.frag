#version 460 core
// Draws a palette scope whose palette has strokes. Reads which palette
// colour every block took (flut5_palette.frag's index output) and draws the
// block in that colour's fill — or in its stroke, when the colour has one
// and a side neighbour holds another colour or nothing. Where two stroked
// colours meet, the one later in the palette draws the edge, so outlines
// stay one block thick. Neighbours past the image's border don't count.
#include <flutter/runtime_effect.glsl>

precision highp float;

// Image size in pixels, one pixel per block.
uniform vec2 u_size;
// Number of palette colours.
uniform float u_count;
// flut5_palette.frag's index output: the palette index's low byte in red,
// its high byte in green, 1 in blue for a drawn block (0 = empty).
uniform sampler2D u_blocks;
// The palette, u_count × 3 pixels, one column per colour: its fill, its
// stroke, and an opaque pixel when it has a stroke.
uniform sampler2D u_palette;

const float kPaletteRows = 3.0;
const float kFillRow = 0.0;
const float kStrokeRow = 1.0;
const float kHasStrokeRow = 2.0;
// The index of an empty block, which no palette colour has.
const float kEmpty = -1.0;

out vec4 frag_color;

vec4 paletteEntry(float index, float row) {
  vec2 texel = vec2((index + 0.5) / u_count, (row + 0.5) / kPaletteRows);
  return texture(u_palette, texel);
}

bool hasStroke(float index) {
  return paletteEntry(index, kHasStrokeRow).a > 0.5;
}

// The palette index stored in a block, or kEmpty.
float paletteIndex(vec4 block) {
  if (block.b <= 0.0) {
    return kEmpty;
  }
  return floor(block.r * 255.0 + 0.5) + 256.0 * floor(block.g * 255.0 + 0.5);
}

// Whether the block of colour [index] draws its stroke along its side
// facing the block whose centre is [neighbour].
bool strokesSide(vec2 neighbour, float index) {
  if (neighbour.x < 0.0 || neighbour.y < 0.0 ||
      neighbour.x > u_size.x || neighbour.y > u_size.y) {
    return false;
  }
  float neighbourIndex = paletteIndex(texture(u_blocks, neighbour / u_size));
  if (neighbourIndex == index) {
    return false;
  }
  if (neighbourIndex == kEmpty) {
    return true;
  }
  // Two stroked colours: the later one in the palette draws the edge.
  return !(neighbourIndex > index && hasStroke(neighbourIndex));
}

bool onEdge(vec2 centre, float index) {
  return strokesSide(centre + vec2(-1.0, 0.0), index) ||
         strokesSide(centre + vec2(1.0, 0.0), index) ||
         strokesSide(centre + vec2(0.0, -1.0), index) ||
         strokesSide(centre + vec2(0.0, 1.0), index);
}

// Palette colours are stored premultiplied; returned straight.
vec4 unpremultiply(vec4 c) {
  return c.a > 0.0 ? vec4(c.rgb / c.a, c.a) : vec4(0.0);
}

void main() {
  vec2 centre = FlutterFragCoord().xy;
  vec4 block = texture(u_blocks, centre / u_size);
  float index = paletteIndex(block);
  if (index == kEmpty) {
    frag_color = vec4(0.0);
    return;
  }
  float row = hasStroke(index) && onEdge(centre, index) ? kStrokeRow : kFillRow;
  vec4 colour = unpremultiply(paletteEntry(index, row));
  // Drawn in full; only a translucent palette colour thins it.
  frag_color = vec4(colour.rgb * colour.a, colour.a);
}
