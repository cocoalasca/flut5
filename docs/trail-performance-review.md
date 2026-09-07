Translucent background review — 2026-09-06

Recommendation: keep the current rendering path and platform defaults. The
experiments below did not identify a broadly useful speedup that justified a
production change. Some resolution loss is acceptable; smooth moving outlines
remain part of the quality requirement.

The review covered the painter, snapshot lifecycle, calibration, filtering,
layered replay, and the source of demos 8 and 6. Demo 8 is the stronger quality
case: eight rotating white outlines, two logical pixels wide, over a low-alpha
blue background. Demo 6 uses moving text with a similarly persistent background.
Only demo 8 was run in the native profiling harness; demo 6 was inspected.

The current implementation already avoids several unnecessary costs: one async
capture in flight, no picture recording on skipped capture frames, direct drawing
for opaque backgrounds, startup resolution calibration, optional overload
throttling, and a shared foreground recording in eligible layered frames.
Overload throttling and layered trails are opt-in; startup calibration is active
with the default floor/ceiling settings.

Two isolated capture alternatives were measured at identical image dimensions:

| Alternative | Native test renderer, 1920×1080 median | Headless Chrome JS, 1920×1080 median |
| --- | ---: | ---: |
| Current scaled image rect + fade | 5.21 ms | 11.00 ms |
| Direct physical-pixel image copy + fade | 5.25 ms | 11.00 ms |
| Fade folded into image color filter | 6.13 ms | 11.10 ms |

These are representative runs with 10 warm-up iterations and 60 measured
iterations, rotating the execution order. Absolute times vary between runs.
The benchmark measures recording plus `toImage()` Future latency, not display
FPS or GPU utilization. Neither alternative provided a meaningful win across
1280×720, 1920×1080, and 2560×1440. The fused filter was consistently slower in
the native test renderer. No production implementation of either was retained.

Pixel comparisons repeat 120 feedback frames, including very low alpha and
changes of fade color. Direct copies matched in the tested cases. The fused
filter matched the native test renderer but accumulated differences on both
web configurations: up to 11/255 in individual premultiplied byte channels.
This does not establish a perceptible defect by itself; the lack of a useful
speedup already makes the trade unattractive.

A temporary copy of demo 8 ran on macOS ARM64 with Flutter 3.44.0 in profile
mode, at an 800×600 logical canvas and DPR 2. A deterministic mouse trajectory
kept the creature moving; the HUD was disabled. Two short default-mode runs
held approximately 60 FPS, with a 17 ms 95th-percentile paint interval and no
in-flight capture drops. Their capture sizes were 1520×1140 and 1600×1200.
Each measured roughly nine seconds after three seconds of warm-up. This is a
baseline at that workload, not evidence of a higher FPS ceiling or a guarantee
for larger canvases/mobile hardware. Attempts to switch modes in the temporary
harness did not produce valid subsequent samples; those modes are excluded.
Jitter was not quantified or validated by a visual motion study.

The main web constraint is below Flut5. In the installed Flutter 3.44.0 SDK,
`CkPicture.toImageSync` draws to a surface, calls `readPixels`, and constructs a
new image with `MakeImage`; `toImage` calls that same path. A cheaper background
draw does not remove that full-image readback/recreation. At 1920×1080, one
RGBA8 payload is about 8.3 MB before additional copies or texture upload.

The skwasm implementation also makes `toImage` call `toImageSync`, but creates a
deferred image from the picture. Its roughly 0.1 ms benchmark latency measures
submission, not the later rendering work. Therefore the existing
`frameSnapshotRasterLoad` HUD value must be interpreted as a capture-latency
budget estimate, not actual GPU occupancy. A useful future improvement is to
supplement it with application frame timings before changing calibration on
that backend. Native capture latency can also include scheduling delay.

For future work, prioritize actual frame-time measurements at the same canvas
size, DPR, trajectory, capture interval, and resolution floor. Retain demo 8 as
the thin-outline quality case and demo 6 as the text case. Do not infer a win
from lowering resolution, increasing skipped frames, or timing only a deferred
image handle. A larger redesign that reduces the captured image area might
help sparse sketches, but must correctly preserve old trails, full-canvas
fades, transforms, clips, resize behavior, and blending. That is a separate
feature, not a proven drop-in optimization.

Reproduce the isolated experiments with
[trail_capture_benchmark_test.dart](../test/trail_capture_benchmark_test.dart):

```sh
flutter test test/trail_capture_benchmark_test.dart --run-skipped
flutter test test/trail_capture_benchmark_test.dart --platform chrome --run-skipped
flutter test test/trail_capture_benchmark_test.dart --platform chrome --wasm --run-skipped
```

SDK source inspected: `engine/src/flutter/lib/web_ui/lib/src/engine/canvaskit/picture.dart`
and `engine/src/flutter/lib/web_ui/lib/src/engine/skwasm/skwasm_impl/picture.dart`
in the local Flutter checkout. Flutter's
[frame timing API](https://api.flutter.dev/flutter/scheduler/SchedulerBinding/addTimingsCallback.html)
and [web profiling guidance](https://docs.flutter.dev/perf/web-performance)
describe the application-level measurements needed alongside these experiments.
