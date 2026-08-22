import 'dart:ui';

/// Returns a new [Path] that traces [source] as a dashed outline.
///
/// [pattern] is a list of segment lengths in pixels, alternating "on"
/// (drawn) and "off" (gap) — matching the HTML5 canvas / p5.js
/// `setLineDash` convention. An odd-length pattern is repeated to make it
/// even, exactly as the canvas spec dictates (so `[5]` becomes `5 on, 5 off`).
///
/// [offset] shifts the starting phase of the pattern (the canvas
/// `lineDashOffset`), letting callers animate a "marching ants" effect.
///
/// Each contour of [source] is dashed independently, starting from [offset],
/// so merged sub-paths (e.g. a batch of shapes) dash the same way they would
/// individually. Returns [source] unchanged when [pattern] has no positive
/// length to walk.
Path dashPath(Path source, List<double> pattern, [double offset = 0]) {
  // Drop negatives (invalid dash lengths) and bail if nothing usable remains.
  final dashes = <double>[for (final d in pattern) if (d >= 0) d];
  if (dashes.isEmpty) return source;

  // Canvas spec: an odd-count pattern is duplicated so on/off alternation is
  // stable across cycles.
  final segs = dashes.length.isOdd ? <double>[...dashes, ...dashes] : dashes;
  final period = segs.fold<double>(0, (a, b) => a + b);
  if (period <= 0) return source;

  final dest = Path();
  for (final metric in source.computeMetrics()) {
    final length = metric.length;
    if (length <= 0) continue;

    // Normalise the offset into [0, period) then walk to the segment the
    // phase lands in, so dashing starts mid-pattern when offset is non-zero.
    double phase = offset % period;
    if (phase < 0) phase += period;
    int i = 0;
    while (phase >= segs[i]) {
      phase -= segs[i];
      i = (i + 1) % segs.length;
    }

    double distance = 0;
    double remaining = segs[i] - phase;
    bool drawn = i.isEven; // even indices are "on", odd are gaps

    while (distance < length) {
      final available = length - distance;
      final step = remaining < available ? remaining : available;
      if (drawn && step > 0) {
        dest.addPath(
          metric.extractPath(distance, distance + step),
          Offset.zero,
        );
      }
      distance += step;
      i = (i + 1) % segs.length;
      remaining = segs[i];
      drawn = !drawn;
    }
  }
  return dest;
}
