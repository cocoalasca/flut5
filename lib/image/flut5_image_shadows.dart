import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// A shadow silhouette baked from a bitmap: white, shaped by the bitmap's own
/// alpha, spread and blurred. Recoloured when it is drawn, so changing a
/// shadow's colour or offset reuses it.
final class Flut5BakedImageShadow(
  final ui.Image image,

  /// Logical pixels added around the draw rect on every side.
  final double pad,

  /// Logical size of [image], [pad] included.
  final Size size,
) {
  late final Rect srcRect = Rect.fromLTWH(
    0,
    0,
    image.width.toDouble(),
    image.height.toDouble(),
  );

  int get bytes => image.width * image.height * 4;
}

/// What makes two baked silhouettes the same: one region of one bitmap, drawn
/// at one size, through one spread and blur.
final class _BakeKey(
  final ui.Image image,
  final Rect src,
  final double width,
  final double height,
  final double pixelRatio,
  final Object filterKey,
) {
  @override
  bool operator ==(Object other) =>
      other is _BakeKey &&
      identical(image, other.image) &&
      src == other.src &&
      width == other.width &&
      height == other.height &&
      pixelRatio == other.pixelRatio &&
      filterKey == other.filterKey;

  @override
  int get hashCode => Object.hash(
    identityHashCode(image),
    src,
    width,
    height,
    pixelRatio,
    filterKey,
  );
}

final class _BakeEntry(final int firstFrame) {
  Flut5BakedImageShadow? baked;
}

/// Baked image-shadow silhouettes, shared by every sketch.
///
/// Blurring a bitmap's alpha takes an offscreen pass, too much to repeat for
/// every shadowed image every frame. So a silhouette is baked the second time
/// it is asked for, in a later frame, and reused from then on. Asking once and
/// never again — a sprite whose size animates — costs no texture at all: the
/// caller draws that shadow live.
///
/// Least recently used bakes leave once the entry count or byte budget is
/// exceeded, and a bitmap's bakes leave when it is disposed.
abstract final class Flut5ImageShadows() {
  static const int _mostEntries = 512;
  static const int _byteBudget = 64 << 20;

  /// Larger than this and the silhouette is drawn live rather than kept.
  static const int _largestBakedExtent = 4096;

  static final LinkedHashMap<_BakeKey, _BakeEntry> _entries = LinkedHashMap();
  static int _bytes = 0;
  static int _frame = 0;

  /// Called once per frame by the render queue.
  static void noteFrameEnded() => _frame++;

  /// Bytes of bakes currently kept. Test-only.
  @visibleForTesting
  static int get debugBytes => _bytes;

  /// The silhouette of [src] of [image] drawn at [size], or `null` when the
  /// caller should draw this one live. [reach] is how far [filter] can spread
  /// it, in logical pixels.
  static Flut5BakedImageShadow? silhouette({
    required ui.Image image,
    required Rect src,
    required Size size,
    required double pixelRatio,
    required Object filterKey,
    required ui.ImageFilter filter,
    required double reach,
  }) {
    final key = _BakeKey(
      image,
      src,
      size.width,
      size.height,
      pixelRatio,
      filterKey,
    );
    final entry = _entries.remove(key);
    if (entry == null) {
      _entries[key] = _BakeEntry(_frame);
      _trim();
      return null;
    }
    _entries[key] = entry; // now the newest
    final baked = entry.baked;
    if (baked != null) return baked;
    if (entry.firstFrame == _frame) return null;
    final fresh = _bake(image, src, size, pixelRatio, filter, reach);
    if (fresh == null) return null;
    entry.baked = fresh;
    _bytes += fresh.bytes;
    _trim();
    return fresh;
  }

  static final Paint _whiteMaskPaint = Paint()
    ..colorFilter = const ColorFilter.mode(Color(0xFFFFFFFF), BlendMode.srcIn)
    ..filterQuality = FilterQuality.medium;
  static final Paint _bakeLayerPaint = Paint();

  static Flut5BakedImageShadow? _bake(
    ui.Image image,
    Rect src,
    Size size,
    double pixelRatio,
    ui.ImageFilter filter,
    double reach,
  ) {
    // Whole pixels, so the silhouette keeps the pixel grid it is drawn on;
    // two spare for the filter's edge rounding.
    final padPixels = (reach * pixelRatio).ceil() + 2;
    final pad = padPixels / pixelRatio;
    final width = (size.width * pixelRatio).ceil() + 2 * padPixels;
    final height = (size.height * pixelRatio).ceil() + 2 * padPixels;
    if (width > _largestBakedExtent || height > _largestBakedExtent) {
      return null;
    }
    final logicalW = width / pixelRatio;
    final logicalH = height / pixelRatio;
    final recorder = ui.PictureRecorder();
    _bakeLayerPaint.imageFilter = filter;
    Canvas(recorder, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()))
      ..scale(pixelRatio)
      ..saveLayer(Rect.fromLTWH(0, 0, logicalW, logicalH), _bakeLayerPaint)
      ..drawImageRect(
        image,
        src,
        Rect.fromLTWH(pad, pad, size.width, size.height),
        _whiteMaskPaint,
      )
      ..restore();
    final picture = recorder.endRecording();
    final baked = picture.toImageSync(width, height);
    picture.dispose();
    return Flut5BakedImageShadow(baked, pad, Size(logicalW, logicalH));
  }

  /// Drops the oldest entries until both budgets fit. The newest entry —
  /// the one just asked for — always stays.
  static void _trim() {
    while (_entries.length > 1 &&
        (_entries.length > _mostEntries || _bytes > _byteBudget)) {
      final oldest = _entries.keys.first;
      _release(_entries.remove(oldest)!);
    }
  }

  static void _release(_BakeEntry entry) {
    final baked = entry.baked;
    if (baked == null) return;
    _bytes -= baked.bytes;
    baked.image.dispose();
  }

  /// Releases every silhouette baked from [image], when it is disposed or
  /// replaced.
  static void evict(ui.Image image) {
    if (_entries.isEmpty) return;
    _entries.removeWhere((key, entry) {
      if (!identical(key.image, image)) return false;
      _release(entry);
      return true;
    });
  }

  /// Releases every silhouette. Test-only.
  @visibleForTesting
  static void clear() {
    _entries.values.forEach(_release);
    _entries.clear();
    _bytes = 0;
  }
}
