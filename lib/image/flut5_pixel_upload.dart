import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/painting.dart';

/// Turns a straight-alpha RGBA buffer — the `pixels` a sketch edits — into a
/// drawable [ui.Image], **synchronously**, so `image()` straight after
/// `updatePixels()` draws the edit and not the previous bitmap.
///
/// Two routes, chosen once per process:
///
/// * **Impeller** (iOS, macOS, Android's default): `decodeImageFromPixelsSync`
///   uploads the buffer directly. It takes *premultiplied* bytes (true of
///   every `PixelFormat.rgba8888` path, async decode included), so the buffer
///   is premultiplied first into [_premultiplied], which is kept between
///   calls so a per-frame `updatePixels()` doesn't allocate a new buffer each
///   frame. The engine copies the bytes before returning, so reusing the
///   buffer is safe.
/// * **Skia and the web**, where that call is unavailable: every pixel is a
///   1×1 sprite of a white texel in one `drawRawAtlas`, tinted with the
///   pixel's own colour, and the picture is rasterized with `toImageSync`.
///   Measured byte-identical to the decode route; slower and more
///   memory-hungry on big images (36 bytes of sprite data per pixel while
///   uploading).
///
/// One uploader per image: it owns that image's scratch buffer.
class Flut5PixelUploader() {
  /// Whether `decodeImageFromPixelsSync` works on this backend. Settled by a
  /// 1×1 probe on first use, not by catching a failed real upload — so a
  /// genuine Impeller failure surfaces instead of silently switching routes.
  static bool? _syncDecodeAvailable;

  /// Opaque white 1×1 bitmap the atlas route tints per pixel. Kept for the
  /// life of the process.
  static ui.Image? _whiteTexel;

  /// Writes sprites over the transparent target instead of blending onto it.
  /// Nearest sampling (the [Paint] default) reads the texel exactly.
  static final Paint _atlasPaint = Paint()..blendMode = BlendMode.src;

  /// Premultiplied copy of the last upload, reused while the size holds.
  Uint8List? _premultiplied;

  /// Cached atlas-upload buffers for Skia / Web so repeated `updatePixels()`
  /// calls at the same dimensions reuse transforms, rects, and colors without
  /// reallocating or rebuilding coordinates every frame.
  Float32List? _atlasTransforms;
  Float32List? _atlasRects;
  Int32List? _atlasColors;
  int _atlasWidth = 0;
  int _atlasHeight = 0;

  /// Forces the atlas route regardless of backend, or restores detection
  /// with `null`. Test-only seam: `flutter test` runs Skia unless
  /// `--enable-impeller` is passed, so each route is reachable either way.
  @visibleForTesting
  static set debugSyncDecodeAvailable(bool? available) =>
      _syncDecodeAvailable = available;

  /// Builds a [width]×[height] bitmap from [straightRgba], four
  /// straight-alpha bytes per pixel, row by row from the top-left.
  ui.Image upload(Uint8ClampedList straightRgba, int width, int height) {
    if (_syncDecodeAvailable ??= _probeSyncDecode()) {
      final premultiplied = _premultiplied?.length == straightRgba.length
          ? _premultiplied!
          : (_premultiplied = Uint8List(straightRgba.length));
      _premultiply(straightRgba, premultiplied);
      return ui.decodeImageFromPixelsSync(
        premultiplied,
        width,
        height,
        ui.PixelFormat.rgba8888,
      );
    }
    _premultiplied = null;
    return _uploadThroughAtlas(straightRgba, width, height);
  }

  /// Frees the scratch buffers. The uploader stays usable.
  void releaseScratch() {
    _premultiplied = null;
    _atlasTransforms = null;
    _atlasRects = null;
    _atlasColors = null;
    _atlasWidth = 0;
    _atlasHeight = 0;
  }

  static bool _probeSyncDecode() {
    // The web build throws UnimplementedError; skip the throw.
    if (kIsWeb) return false;
    try {
      ui
          .decodeImageFromPixelsSync(
            Uint8List(4),
            1,
            1,
            ui.PixelFormat.rgba8888,
          )
          .dispose();
      return true;
    } catch (_) {
      // Skia throws a bare String ("… is not implemented on Skia.").
      return false;
    }
  }

  /// Copies [straight] into [premultiplied], scaling each colour channel by
  /// its pixel's alpha with round-half-up — the same rounding the GPU
  /// applies, so both upload routes produce identical bitmaps.
  static void _premultiply(Uint8ClampedList straight, Uint8List premultiplied) {
    if (Endian.host == Endian.little &&
        (straight.offsetInBytes & 3) == 0 &&
        (premultiplied.offsetInBytes & 3) == 0 &&
        (straight.length & 3) == 0) {
      final src32 = straight.buffer.asUint32List(
        straight.offsetInBytes,
        straight.length >> 2,
      );
      final dst32 = premultiplied.buffer.asUint32List(
        premultiplied.offsetInBytes,
        premultiplied.length >> 2,
      );
      for (var i = 0; i < src32.length; i++) {
        final px = src32[i];
        final alpha = px >>> 24;
        if (alpha == 255) {
          dst32[i] = px;
        } else if (alpha == 0) {
          dst32[i] = 0;
        } else {
          final r = _scaleByAlpha(px & 0xFF, alpha);
          final g = _scaleByAlpha((px >>> 8) & 0xFF, alpha);
          final b = _scaleByAlpha((px >>> 16) & 0xFF, alpha);
          dst32[i] = (alpha << 24) | (b << 16) | (g << 8) | r;
        }
      }
      return;
    }
    for (var offset = 0; offset < straight.length; offset += 4) {
      final alpha = straight[offset + 3];
      premultiplied[offset + 3] = alpha;
      if (alpha == 255) {
        premultiplied[offset] = straight[offset];
        premultiplied[offset + 1] = straight[offset + 1];
        premultiplied[offset + 2] = straight[offset + 2];
      } else {
        premultiplied[offset] = _scaleByAlpha(straight[offset], alpha);
        premultiplied[offset + 1] = _scaleByAlpha(straight[offset + 1], alpha);
        premultiplied[offset + 2] = _scaleByAlpha(straight[offset + 2], alpha);
      }
    }
  }

  /// `round(channel × alpha / 255)` without a division: exact for every
  /// 8-bit pair (checked exhaustively by the tests).
  @visibleForTesting
  static int scaleByAlpha(int channel, int alpha) =>
      _scaleByAlpha(channel, alpha);

  static int _scaleByAlpha(int channel, int alpha) {
    final product = channel * alpha + 128;
    return (product + (product >> 8)) >> 8;
  }

  ui.Image _uploadThroughAtlas(
    Uint8ClampedList straightRgba,
    int width,
    int height,
  ) {
    final texel = _whiteTexel ??= _buildWhiteTexel();
    final spriteCount = width * height;

    Float32List transforms;
    Float32List sourceRects;
    Int32List colors;
    if (_atlasWidth == width &&
        _atlasHeight == height &&
        _atlasTransforms != null &&
        _atlasRects != null &&
        _atlasColors != null) {
      transforms = _atlasTransforms!;
      sourceRects = _atlasRects!;
      colors = _atlasColors!;
    } else {
      // RSTransform [scos, ssin, tx, ty] and source rect [l, t, r, b] per
      // sprite; invariant for a given (width, height), so build once and reuse.
      transforms = _atlasTransforms = Float32List(spriteCount * 4);
      sourceRects = _atlasRects = Float32List(spriteCount * 4);
      colors = _atlasColors = Int32List(spriteCount);
      _atlasWidth = width;
      _atlasHeight = height;
      var sprite = 0;
      for (var y = 0; y < height; y++) {
        final top = y.toDouble();
        for (var x = 0; x < width; x++) {
          final offset = sprite * 4;
          transforms[offset] = 1;
          transforms[offset + 2] = x.toDouble();
          transforms[offset + 3] = top;
          sourceRects[offset + 2] = 1;
          sourceRects[offset + 3] = 1;
          sprite++;
        }
      }
    }

    for (var sprite = 0, offset = 0; sprite < spriteCount; sprite++, offset += 4) {
      // Straight ARGB; the GPU premultiplies it. Int32List keeps the low
      // 32 bits, so an alpha above 127 wrapping negative is intended.
      colors[sprite] =
          straightRgba[offset + 3] << 24 |
          straightRgba[offset] << 16 |
          straightRgba[offset + 1] << 8 |
          straightRgba[offset + 2];
    }
    final recorder = ui.PictureRecorder();
    // BlendMode.dst keeps the colour and discards the texel — `colors` are the
    // destination of the per-sprite blend, the texture its source.
    Canvas(recorder).drawRawAtlas(
      texel,
      transforms,
      sourceRects,
      colors,
      BlendMode.dst,
      null,
      _atlasPaint,
    );
    final picture = recorder.endRecording();
    final image = picture.toImageSync(width, height);
    picture.dispose();
    return image;
  }

  static ui.Image _buildWhiteTexel() {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 1, 1),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final picture = recorder.endRecording();
    final texel = picture.toImageSync(1, 1);
    picture.dispose();
    return texel;
  }
}
