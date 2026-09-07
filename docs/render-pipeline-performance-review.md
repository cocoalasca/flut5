Render pipeline review — 2026-09-06

The existing pipeline already removes substantial CPU recording work through
packed point/line buffers, shared paths for compatible shapes, translation
folding, immutable paint snapshots, and same-image atlas runs. Retained changes
are deliberately small: skip unused vertex-bound calculations and correct the
empty-queue check for pending images. No resolution, sampling, frame cadence,
cache limits, geometry, or batching boundaries changed.

Custom vertex shapes previously scanned their endpoint coordinates on every
`endShape()` to compute gradient bounds. Solid paints and gradients with an
explicit rectangle immediately discarded those bounds. Now this extra O(n)
pass runs only when a fill or stroke gradient needs automatic bounds. Path
construction and its own lazily computed content bounds remain unchanged.

The queue's `isEmpty` getter omitted pending atlas entries. Consequently, a
frame containing only batchable images could take the painter's empty-frame
branch and lose those images when the queue cleared. Including the atlas count
fixes this without forcing an early flush or adding allocations. A regression
test failed before the fix; tests now cover single/multiple pending images,
clearing the queue, and pixels painted by an image-only sketch.

CPU measurements

Flutter 3.44.0 / Dart 3.12.0, macOS ARM64 native debug test runner. The new
benchmark records 80 frames per scenario, discards the first 20, and measures
queue construction, display-list recording, and cleanup. These are separate
process runs, with normal JIT/scheduling variation; they are not GPU timings,
release-build predictions, or demonstrated application FPS gains.

| Workload | Before p50 / p95 | After p50 / p95 |
| --- | --- | --- |
| 2,400 rectangles | 0.319 / 0.396 ms | 0.317 / 0.383 ms |
| 2,400 lines | 0.159 / 0.223 ms | 0.151 / 0.210 ms |
| 2,400 custom four-vertex shapes | 1.520 / 2.285 ms | 1.341 / 1.919 ms |
| One 20,000-vertex path | 0.790 / 0.965 ms | 0.714 / 0.755 ms |
| 7,200 mixed rectangles/lines/circles | 1.041 / 1.105 ms | 1.033 / 1.093 ms |

Each scenario still collapses into one queue item with its compatible paints.
The custom-vertex cases recorded about 10–12% faster at the median in this pair
of runs. Absolute savings were 0.076–0.179 ms; modest changes in unaffected
scenarios should be treated as noise. A queue item can issue multiple canvas
calls, such as separate fill and stroke passes.

The existing image benchmark also confirms that its current batching is useful:

| Same-source tiles | Individual items | Atlas batch | CPU ratio |
| --- | --- | --- | --- |
| 100 | 0.116 ms | 0.093 ms | 1.2× |
| 900 | 0.323 ms | 0.140 ms | 2.3× |
| 2,400 | 0.578 ms | 0.112 ms | 5.2× |

Those are existing atlas benefits, not improvements introduced in this review.
The atlas combines consecutive compatible instances of the same image;
different images, transforms that must be materialized, shadows, and
non-proportional scaling still require the appropriate separate operations.

Text remains texture-cached rendering rather than a cross-texture atlas. The
dynamic renderer draws cached glyphs, while static text reuses whole-string
images. Warmed demo-6-style unwrapped animated spacing measured 0.064 ms p50,
with eight textures and one layout in the existing text benchmark. Its exact
letter spacing and line height remain composition-time attributes; see the
[text cache review](text-cache-performance-review.md) for wrapping semantics
and cache-growth findings. Packing every glyph into a shared atlas would be a
larger cache/upload/eviction design, not a safe small queue optimization.

Decisions about further changes

- Keep type/paint/order boundaries. Translucency, blending, gradients, shadows,
  and overlap make arbitrary merging or sorting by texture unsafe. Existing
  shared-path batching also groups fill/stroke/shadow passes; expanding its
  eligibility needs visual comparisons, not just lower queue-item counts.
- Keep the owned typed-array copies at flush. Queue buffers are reused after
  `clear()`, while retained items and split replays need stable payloads. A view
  into the reused buffer would change earlier geometry. Removing copies needs
  an explicit lifetime/pool design and measurements to justify it.
- Keep the shader and paint snapshot caches. Memoizing batch eligibility by
  `Paint` identity alone would assume that publicly supplied mutable paints
  never change.
- Keep lazy path bounds and the existing background replay scheme. This review
  did not establish a useful gain from replacing them or adding bookkeeping
  to every queue mutation.

Reproduce the CPU workloads with:

```sh
flutter test test/render_pipeline_benchmark_test.dart --run-skipped
flutter test test/image_atlas_benchmark_test.dart --run-skipped
flutter test test/text_cache_benchmark_test.dart --run-skipped
```

Device FPS, mobile GPU performance, and maximum sustainable trail resolution
were not measured by these queue benchmarks. The changes use the same Dart
pipeline across platforms, with rendering validation recorded below.

Validation

- Full native suite: 358 tests passed; seven manual benchmarks/experiments
  skipped.
- Chrome JavaScript and Chrome WebAssembly: all 14 atlas tests plus the 49
  vertex, translation/batching, and dynamic-text rendering tests passed on
  each backend. This includes gradient bounds, image-only painter output,
  atlas/unbatched pixel equivalence, and animated spacing/line-height reuse.
- Browser runs were scoped to rendering. An initial wider JavaScript run was
  stopped when the unrelated missing-image-asset loading test did not finish;
  image-loading failure behavior is covered by the native suite, not claimed
  as validated on the web by this review.
