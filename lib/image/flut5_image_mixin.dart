import 'package:flutter/material.dart';

import '../core/flut5_console.dart';
import '../shape/flut5_fill.dart';
import 'flut5_image.dart';

/// Bitmap loading and drawing for the Flut5 engine.
///
/// Mirrors p5.js's image surface: [loadImage] decodes a file into a
/// [Flut5Image], [image] blits it onto the canvas, and [Flut5Image.resize]
/// reshapes the bitmap itself.
///
/// Images ignore [fill] and `stroke()` — a bitmap carries its own colors — but
/// they do respect `blendMode()`, `shadow()`, and every transform, clip and
/// container the surrounding drawing code sets up.
mixin Flut5ImageMixin on Flut5Fill {
  /// Loads an image and returns it once decoded.
  ///
  /// Accepts an asset **name** (`'logo'`, `'logo.png'`), an asset **path**
  /// (`'assets/images/logo.png'`), an `http://` / `https://` **URL**, a
  /// `Uint8List` of encoded bytes, an already-decoded `ui.Image`, or any
  /// Flutter `ImageProvider`. Names resolve against the assets declared in
  /// `pubspec.yaml` — the same convenience `textFont()` gives registered font
  /// families. See [Flut5Image.load] for the full resolution rules.
  ///
  /// `setup()` may be `async`, and the first frame does not run until it
  /// completes, so awaiting there is the p5 `preload()` equivalent:
  ///
  /// ```dart
  /// late final Flut5Image logo;
  ///
  /// @override
  /// Future<void> setup() async {
  ///   logo = await loadImage('logo.png');
  /// }
  ///
  /// @override
  /// void draw() => image(logo, 20, 20);
  /// ```
  ///
  /// Throws a [FlutterError] naming the available assets when the source
  /// cannot be read, and an [ArgumentError] for an unsupported source type.
  Future<Flut5Image> loadImage(dynamic source) => Flut5Image.load(source);

  /// Draws [img] with its top-left corner at ([x], [y]).
  ///
  /// Position is the corner, matching `rect()` (and p5's default `CORNER`
  /// image mode). With no [width]/[height] the image draws at its own pixel
  /// size; supply them to scale it:
  ///
  /// ```dart
  /// image(logo, 20, 20);            // natural size
  /// image(logo, 20, 20, 120, 60);   // stretched into a 120×60 box
  /// ```
  ///
  /// The trailing four arguments select a sub-rectangle of the source — the
  /// sprite-sheet form, mirroring p5's
  /// `image(img, dx, dy, dWidth, dHeight, sx, sy, sWidth, sHeight)`:
  ///
  /// ```dart
  /// // Draw the 32×32 tile at column 3, row 1 of a sprite sheet, doubled.
  /// image(sheet, x, y, 64, 64, 96, 32, 32, 32);
  /// ```
  ///
  /// [sx]/[sy] default to the image's top-left and [sWidth]/[sHeight] to the
  /// rest of the image. A source rectangle that runs past the image edge is
  /// clamped (with a warning) rather than sampling garbage; a zero or
  /// negative draw size is a no-op.
  ///
  /// Scaling happens on the GPU every frame. Drawing a 4000px photo into a
  /// 300px box resamples 178× more pixels than it needs to — call
  /// [Flut5Image.resize] once at load time instead.
  void image(
    Flut5Image img,
    double x,
    double y, [
    double? width,
    double? height,
    double? sx,
    double? sy,
    double? sWidth,
    double? sHeight,
  ]) {
    if (batchPath != null) {
      // A bitmap is a texture op and cannot merge into the batch `Path`,
      // exactly like rasterized text.
      throw FlutterError('image() cannot be called inside beginBatch/endBatch');
    }
    if (img.isDisposed) {
      Flut5Console.printLater(
        'image() skipped: the image loaded from "${img.source}" was disposed.',
      );
      return;
    }

    final imageWidth = img.width.toDouble();
    final imageHeight = img.height.toDouble();
    if (imageWidth <= 0 || imageHeight <= 0) return;

    final double sourceX = sx ?? 0;
    final double sourceY = sy ?? 0;
    var source = Rect.fromLTWH(
      sourceX,
      sourceY,
      sWidth ?? (imageWidth - sourceX),
      sHeight ?? (imageHeight - sourceY),
    );
    if (source.width <= 0 || source.height <= 0) return;

    if (source.left < 0 ||
        source.top < 0 ||
        source.right > imageWidth ||
        source.bottom > imageHeight) {
      final clamped = source.intersect(
        Rect.fromLTWH(0, 0, imageWidth, imageHeight),
      );
      if (clamped.width <= 0 || clamped.height <= 0) {
        Flut5Console.printLater(
          'image() skipped: the source rectangle '
          '(${source.left}, ${source.top}, ${source.width}, ${source.height}) '
          'lies entirely outside the ${img.width}×${img.height} image '
          '"${img.source}".',
        );
        return;
      }
      Flut5Console.printLater(
        'image(): the source rectangle '
        '(${source.left}, ${source.top}, ${source.width}, ${source.height}) '
        'runs past the ${img.width}×${img.height} image "${img.source}" and '
        'was clamped to '
        '(${clamped.left}, ${clamped.top}, ${clamped.width}, ${clamped.height}). '
        'The drawn size is unchanged, so the result is stretched — pass a '
        'source rectangle inside the image to avoid it.',
      );
      source = clamped;
    }

    final drawWidth = width ?? source.width;
    final drawHeight = height ?? source.height;
    if (drawWidth <= 0 || drawHeight <= 0) return;

    renderQueue.appendImage(
      img.uiImage,
      source,
      Rect.fromLTWH(x, y, drawWidth, drawHeight),
      currentBlendMode,
    );
  }
}
