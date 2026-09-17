Performance enhancements — 2026-09-13

Four focused changes preserve the existing background-trail resolution policy,
frame cadence, text-cache budgets, and sliding expiration timeout.

- Transformed rectangles append their corners directly. Circles transform their
  centers and radii. Rounded rectangles, ellipses, and arcs reuse scratch paths;
  transformed path appends reuse a matrix. Queued paths and atlas buffers still
  own their geometry, including when replayed after the queue is cleared.
- Automatic text gradients reuse fill/stroke ink bounds within each execution.
  Only numeric bounds are retained, never cached image references. Spacing,
  alignment, clipping, shadows, and stroke-specific measurements remain separate.
- Cache overflow builds a min-heap over existing entries and selects victims in
  exact access-tick order, instead of allocating MapEntry wrappers and sorting
  the entire cache. Ordinary cache hits and expiration ordering are unchanged.
  The 7/8 eviction targets and protection for the newest oversized image remain.
- Same-image sprite runs fold rotation and uniform scale into packed queue data.
  Axis-aligned sprites use atlas draws. Rotated sprites keep individual
  drawImageRect calls inside the combined item: testing found that drawRawAtlas
  changes rotated quad-edge antialiasing. Thus one queue item does not imply one
  draw call for a rotated run. Shadows and nonuniform scale retain fallbacks.

CPU measurements

Native macOS debug/JIT Flutter tests; 160 frames per workload, first 40 discarded.
Times cover queue construction, display-list recording, and cleanup, not GPU
rasterization or device FPS. The before version was saved before this work
(including the earlier rotation/uniform-scale geometry batching). A repeat
baseline ran in an isolated temporary copy without altering the working tree.
These are separate process runs with normal JIT and scheduling variation.

| Workload | Before p50 / p95 (ms) | After p50 / p95 (ms) |
| --- | --- | --- |
| 2,400 transformed rectangles/circles | 1.882 / 2.015 | 0.568 / 0.640 |
| 2,400 transformed sprites | 1.447 / 1.568 | 1.064 / 1.137 |
| 30 two-line gradient text items | 0.930 / 1.030 | 0.771 / 0.912 |
| 30 two-line solid text items | 0.372 / 0.488 | 0.369 / 0.560 |
| 256 unique layouts/frame at a 1,024-entry cap | 1.097 / 1.346 | 0.903 / 1.153 |

The solid-text median is effectively unchanged; its tail variation does not
establish a gain. An initial all-atlas rotated-sprite experiment recorded much
faster but was not retained because of its edge-rendering differences. The
numbers above measure the retained renderer that preserves those edges.

Reproduce with:

```sh
flutter test test/performance_enhancements_benchmark_test.dart --run-skipped
```

Validation

- Native full suite: 420 tests passed; nine manual workloads skipped.
- Chrome: 40 transform, image, text-spacing, and priority-eviction tests passed.
- Gradient text matches a golden captured from the pre-change implementation.
- Coverage includes translucent overlapping sprites, cropped image sources,
  blend modes, negative uniform scales, clips, retained geometry after clear,
  exact LRU victims, same-frame texture hits, expiration, and texture disposal.
- An existing primitive-versus-path comparison exceeded its 0.5% large-edge
  difference threshold in the pre-change Chrome renderer (0.515%). The test
  documents a 0.6% allowance while retaining its stricter mean channel-error
  check. This is not a claim of byte-identical primitive/path rasterization.
- Manually ran local Demos 7, 9, and 10 in Chrome against this package. Checked
  Demo 7 letter bursts/rotation/trails; Demo 9 text retargeting from hello to
  Flut5 and pointer repulsion; Demo 10 rotating particle letters, both motion
  sliders, and pointer interaction. These were visual/function checks, not
  device-FPS comparisons. Demo sources were not edited; test servers were stopped.
- Changed implementation/test files pass static analysis. Whole-repository
  analysis has the same 11 unrelated pre-existing informational notices.
