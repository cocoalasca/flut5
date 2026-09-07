Text cache review — 2026-09-06

The existing glyph texture cache and its growth policy are a good fit for the
current drawing model. Keep the configured entry ceilings, 128 MiB texture-byte
budget, and bilinear sampling defaults. One focused optimization was retained:
unwrapped dynamic text now reuses its layout while letter spacing animates.

Previously, each distinct spacing value was part of the layout key. The glyph
textures were reusable, but a miss still tokenized the text, fetched advances
and kerning, allocated offsets, and retained another layout. Demo 6's fifteen
rows of `Hello World` exercise this pattern.

For `textDynamic()` (also the default `text()` mode) with no `maxWidth`, the
renderer now requests the zero-spacing layout and adds spacing when drawing:
each glyph moves by its source character position times the spacing, and the
line width grows by the number of inter-character gaps times the spacing.
Source positions include whitespace. This also feeds alignment, gradient bounds,
and shadows. No spacing quantization, texture downscaling, or filtering change
is involved. The layout holds geometry, not texture references, so eviction
continues to work. Wrapped text still uses spacing-dependent layouts because
spacing can change its line breaks. Static text rendering is unchanged.

The benchmark reproduces the demo 6 spacing formula with the test font, without
background-trail capture. It records 15 rows per frame for 1,200 frames and
measures the final 1,000. Flutter 3.44.0, native debug test runner:

| Workload | Before p50 / p95 | After p50 / p95 | Retained layouts before → after |
| --- | --- | --- | --- |
| Stable text and spacing | 0.072 / 0.123 ms | 0.070 / 0.115 ms | 1 → 1 |
| Animated spacing, unwrapped | 0.073 / 0.101 ms | 0.064 / 0.082 ms | 2,961 → 1 |
| Animated spacing, wrapped | 0.077 / 0.107 ms | 0.078 / 0.102 ms | 2,961 → 2,961 |
| Changing numeric labels | 0.104 / 0.148 ms | 0.108 / 0.140 ms | 15,951 → 15,951 |

The strongest result is eliminating spacing-driven layout-cache growth. The
CPU gain is small in absolute terms—about 9 microseconds per measured frame
in the animated-spacing case—and does not establish an application FPS gain.
Times are separate process runs and include normal measurement variation.
The animated-spacing case retained the same eight textures and 783,360
estimated RGBA bytes before and after. No GPU texture memory saving is claimed;
the saved layouts are Dart-side objects. Unwrapped layouts now retain a small
source-position array to support composition-time spacing.

Validation: 351 package tests passed, with six manual benchmarks/experiments
skipped. The five new geometry/rendering tests also passed on JavaScript web
and WebAssembly web. Tests compare against spacing-baked layouts and rendering,
covering fractional/negative spacing, whitespace, Unicode code points, line
breaks, alignment, gradients, shadows, clipping, rotation, and texture eviction.
Pixel comparisons matched exactly in the tested cases; geometry comparisons
allow 1e-9 for floating-point reassociation. Mobile device FPS and the actual
Kihim font from demo 6 were not profiled.

Other observations about the existing limits:

- Growing before eviction avoids repeated rasterization when a reusable
  working set slightly exceeds the initial cap. The existing tests cover this.
- The texture-byte counter is an RGBA estimate, not total process or GPU memory.
  A single oversized entry is deliberately retained even if it exceeds the
  byte budget, so the image returned to the renderer is not already disposed.
- Layouts have a count ceiling, not a byte ceiling. Width, kerning, and line
  metric maps are retained until `clear()` and do not share that ceiling.
  Continuously unique font sizes or measured strings can still accumulate
  metadata; increasing the texture budget would not address that pattern.
- Device pixel ratio is cached separately and is not reset by `clear()`.
  Cross-display/DPR changes deserve a separate correctness check before
  treating texture sharpness on those transitions as a cache-budget issue.

The last two observations were not changed in this optimization. They do not
affect the fixed-font, fixed-DPR spacing workload, and need their own cache
invalidation/residency design rather than an arbitrary reduction of limits.

Reproduce CPU measurements with
[text_cache_benchmark_test.dart](../test/text_cache_benchmark_test.dart):

```sh
flutter test test/text_cache_benchmark_test.dart --run-skipped
```

Rendering checks are in
[text_spacing_layout_test.dart](../test/text_spacing_layout_test.dart), also
runnable with `--platform chrome` or `--platform chrome --wasm`.
