import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;

import '../core/flut5_console.dart';
import 'flut5_image_handles.dart';
import 'flut5_pixel_upload.dart';

/// Asset extensions Flutter can decode. The asset manifest lists every
/// declared asset — fonts, JSON, shaders — so the name index is filtered to
/// the ones [Flut5Image.load] could actually open, keeping short names
/// unambiguous and the "no such image" error honest.
const Set<String> _imageExtensions = {
  '.png',
  '.jpg',
  '.jpeg',
  '.webp',
  '.gif',
  '.bmp',
  '.wbmp',
};

/// A decoded bitmap, ready to draw with `image()`.
///
/// The Flut5 counterpart of p5.js's `p5.Image`. Obtain one with
/// `loadImage()` (or [Flut5Image.load]); draw it with
/// `image(img, x, y)`; reshape it in place with [resize]; read and edit its
/// pixels with [loadPixels], [pixels], [get], [set] and [updatePixels]; cut a
/// piece out as a new image with [getRegion]. `createImage()` (or
/// [Flut5Image.create]) makes a blank one to fill in.
///
/// ```dart
/// class Sketch extends Flut5Sketch {
///   late final Flut5Image logo;
///
///   @override
///   Future<void> setup() async {
///     logo = await loadImage('logo');  // or 'assets/images/logo.png'
///     logo.resize(200, 0);             // 200 wide, height keeps the ratio
///   }
///
///   @override
///   void draw() {
///     background(Colors.white);
///     image(logo, 40, 40);
///   }
/// }
/// ```
///
/// [width] and [height] are the decoded pixel dimensions, and — as in p5 —
/// they double as the *logical* size the image draws at when no explicit size
/// is passed to `image()`. A 400×300 file drawn with `image(img, 0, 0)`
/// covers 400×300 logical pixels regardless of the display's device pixel
/// ratio.
///
/// The underlying [ui.Image] is a native resource. It is freed when the
/// [Flut5Image] is [dispose]d; a sketch that loads a fixed set of images in
/// `setup()` and keeps them for its lifetime never needs to call it.
class Flut5Image._(
  var ui.Image _image,

  /// Where this image came from — an asset key, a URL, or a placeholder for
  /// in-memory sources. Used to make warnings identify the culprit.
  final String source,
) {
  /// Wraps an already-decoded [ui.Image] — an escape hatch for bitmaps that
  /// came from somewhere other than [load], such as the engine's
  /// `frameSnapshot` or a `PictureRecorder` of your own.
  ///
  /// Ownership transfers: [dispose] (and [resize], which replaces the bitmap)
  /// disposes [image]. Pass `image.clone()` to keep your own handle alive.
  /// [source] only labels the image in warnings.
  Flut5Image.fromUiImage(ui.Image image, {String source = '<ui.Image>'})
    : this._(image, source);

  /// A blank, fully transparent [width]×[height] image whose [pixels] are
  /// ready to edit straight away. The engine's `createImage()` forwards here.
  ///
  /// Throws a [RangeError] for a [width] or [height] below 1.
  factory Flut5Image.create(int width, int height) {
    _checkExtent(width, height);
    // All zeros is exactly what the transparent bitmap reads back as, so
    // there is nothing to load.
    return Flut5Image._(
      _paintBitmap(width, height, null),
      'createImage($width, $height)',
    ).._pixels = Uint8ClampedList(width * height * 4);
  }

  /// Upper bound on each side of a created image or region — far past any
  /// GPU's texture limit, it only stops a typo from allocating gigabytes of
  /// pixels before the GPU gets the chance to refuse.
  static const int _maxCreateExtent = 1 << 15;

  static void _checkExtent(int width, int height) {
    RangeError.checkValueInInterval(width, 1, _maxCreateExtent, 'width');
    RangeError.checkValueInInterval(height, 1, _maxCreateExtent, 'height');
  }

  /// Rasterizes a transparent [width]×[height] bitmap, with whatever [paint]
  /// draws on it (nothing when `null`).
  static ui.Image _paintBitmap(
    int width,
    int height,
    void Function(Canvas canvas)? paint,
  ) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    paint?.call(canvas);
    final picture = recorder.endRecording();
    final bitmap = picture.toImageSync(width, height);
    picture.dispose();
    return bitmap;
  }

  bool _disposed = false;

  /// The decoded bitmap. Valid until [dispose]; replaced by [resize] and
  /// [updatePixels], after which a handle read earlier is no longer this
  /// image's and may already be freed — read it again rather than keeping it.
  ui.Image get uiImage => _image;

  /// Width of the decoded bitmap, in pixels. Also the logical width the image
  /// draws at when `image()` is called without an explicit size.
  int get width => _disposed ? 0 : _image.width;

  /// Height of the decoded bitmap, in pixels. Also the logical height the
  /// image draws at when `image()` is called without an explicit size.
  int get height => _disposed ? 0 : _image.height;

  /// True once [dispose] has run. Drawing a disposed image is a no-op that
  /// warns rather than a crash.
  bool get isDisposed => _disposed;

  // ── Loading ───────────────────────────────────────────────────────────

  /// Decodes an image from [source]. The engine's `loadImage()` forwards
  /// here.
  ///
  /// Accepts:
  /// * a **name** — `'logo'` or `'logo.png'` — matched against the assets
  ///   declared in `pubspec.yaml`, the same way `textFont()` takes a
  ///   registered font family rather than a path,
  /// * a **path** — `'assets/images/logo.png'`, the full asset key,
  /// * a **URL** — any `http://` or `https://` address,
  /// * a [Uint8List] of encoded file bytes (PNG, JPEG, WebP, GIF, BMP),
  /// * a [ui.Image] that is already decoded,
  /// * any Flutter [ImageProvider] (`FileImage`, `AssetImage`, …).
  ///
  /// Names are resolved from the asset manifest Flutter generates at build
  /// time, so a newly added asset needs a restart (not a hot reload) to be
  /// found by name. A name matching assets in two different folders is
  /// ambiguous: the first by path order wins and a warning names the
  /// alternatives — pass the full path to pin it.
  ///
  /// Animated GIFs decode to their first frame.
  static Future<Flut5Image> load(dynamic source) async {
    if (source is Flut5Image) return source;
    if (source is ui.Image) return Flut5Image.fromUiImage(source);
    if (source is Uint8List) {
      return Flut5Image._(await _decodeBytes(source, '<bytes>'), '<bytes>');
    }
    if (source is ImageProvider) {
      return Flut5Image._(await _resolveProvider(source), '$source');
    }
    if (source is String) {
      if (_isNetworkUrl(source)) {
        return Flut5Image._(
          await _resolveProvider(NetworkImage(source)),
          source,
        );
      }
      final key = await _resolveAssetKey(source);
      final ByteData data;
      try {
        data = await rootBundle.load(key);
      } catch (error) {
        throw FlutterError(_assetErrorMessage(source, key, error));
      }
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      return Flut5Image._(await _decodeBytes(bytes, key), key);
    }
    throw ArgumentError(
      'loadImage() expects a String asset name, asset path or URL, a '
      'Uint8List of encoded bytes, a ui.Image, or an ImageProvider. '
      'Got ${source.runtimeType}.',
    );
  }

  static bool _isNetworkUrl(String source) =>
      source.startsWith('http://') || source.startsWith('https://');

  // ── Asset name index ──────────────────────────────────────────────────

  /// Short name → asset key, built once per process from the manifest Flutter
  /// generates at build time. Every image asset is indexed under its full
  /// key, its file name (`logo.png`) and its stem (`logo`).
  ///
  /// The resolved map is cached, deliberately not the [Future] — the same
  /// reason the font registry caches its value: under `flutter_test` each
  /// test runs in its own fake-async zone, and a future created in a previous
  /// test's zone never completes.
  static Map<String, String>? _assetIndex;

  /// Short names that matched more than one asset, mapped to every candidate.
  /// Looked up only on a hit, so unambiguous sketches pay nothing.
  static Map<String, List<String>> _ambiguousAssets = const {};

  /// Drops the process-wide asset index so the next load re-reads the
  /// manifest. Test-only seam, mirroring `debugResetRegisteredFonts`.
  @visibleForTesting
  static void debugResetAssetIndex() {
    _assetIndex = null;
    _ambiguousAssets = const {};
  }

  /// Maps [source] onto a real asset key. Exact keys and known names resolve
  /// from the index; anything else is passed through so assets outside the
  /// manifest (a `packages/…` key, a dynamically bundled file) still load.
  static Future<String> _resolveAssetKey(String source) async {
    var name = source;
    while (name.startsWith('./')) {
      name = name.substring(2);
    }
    final index = _assetIndex ??= await _buildAssetIndex();
    final key = index[name];
    if (key == null) return name;
    final rivals = _ambiguousAssets[name];
    if (rivals != null) {
      Flut5Console.printLater(
        'loadImage("$source") is ambiguous — ${rivals.length} assets share '
        'that name (${rivals.join(', ')}). Loaded "$key"; pass the full path '
        'to choose a different one.',
      );
    }
    return key;
  }

  static Future<Map<String, String>> _buildAssetIndex() async {
    List<String> assets;
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      assets = manifest.listAssets();
    } catch (_) {
      // No manifest (a bare test binding, or a build with no assets at all).
      // Names then resolve to themselves and `rootBundle.load` reports the
      // miss with its own message.
      return const {};
    }

    // Sorted so a name shared by two folders resolves to the same asset on
    // every run and platform — an arbitrary-but-stable winner beats a
    // manifest-order one that can shift between builds.
    assets = assets.where(_isImageAsset).toList()..sort();

    final index = <String, String>{};
    final collisions = <String, List<String>>{};
    for (final key in assets) {
      index[key] = key;
      final slash = key.lastIndexOf('/');
      final fileName = slash < 0 ? key : key.substring(slash + 1);
      final dot = fileName.lastIndexOf('.');
      final stem = dot <= 0 ? fileName : fileName.substring(0, dot);
      for (final alias in {fileName, stem}) {
        // A full key always wins over a short name that happens to match it.
        if (index[alias] == alias) continue;
        final existing = index[alias];
        if (existing == null) {
          index[alias] = key;
        } else {
          (collisions[alias] ??= <String>[existing]).add(key);
        }
      }
    }
    _ambiguousAssets = collisions.isEmpty ? const {} : collisions;
    return index;
  }

  static bool _isImageAsset(String key) {
    final dot = key.lastIndexOf('.');
    if (dot < 0) return false;
    return _imageExtensions.contains(key.substring(dot).toLowerCase());
  }

  /// Builds the "no such image" message, listing what *is* available so a
  /// typo or a missing `pubspec.yaml` entry is obvious from the console.
  static String _assetErrorMessage(String source, String key, Object error) {
    final buffer = StringBuffer()
      ..writeln('loadImage() could not read the asset "$source": $error');
    if (key != source) buffer.writeln('Resolved to the asset key "$key".');
    final known = (_assetIndex ?? const {}).values.toSet().toList()..sort();
    if (known.isEmpty) {
      buffer.write(
        'No image assets are declared in pubspec.yaml. Add one under '
        '`flutter: assets:` and restart (hot reload does not rebuild the '
        'asset manifest).',
      );
    } else {
      final shown = known.take(12).join(', ');
      final rest = known.length > 12 ? ' … and ${known.length - 12} more' : '';
      buffer.write('Available image assets: $shown$rest.');
    }
    return buffer.toString();
  }

  // ── Decoding ──────────────────────────────────────────────────────────

  /// Decodes the first frame of an encoded byte buffer. Mirrors `dart:ui`'s
  /// own `decodeImageFromList`, but surfaces decode errors instead of
  /// swallowing them.
  static Future<ui.Image> _decodeBytes(Uint8List bytes, String label) async {
    final ui.Codec codec;
    try {
      codec = await ui.instantiateImageCodec(bytes);
    } catch (error) {
      throw FlutterError(
        'loadImage() could not decode "$label": $error\n'
        'Supported formats are PNG, JPEG, WebP, GIF and BMP.',
      );
    }
    final ui.FrameInfo frame;
    try {
      frame = await codec.getNextFrame();
    } finally {
      codec.dispose();
    }
    return frame.image;
  }

  /// Resolves an [ImageProvider] — including the [NetworkImage] behind a URL
  /// source — to a single [ui.Image].
  ///
  /// The provider's result is owned by Flutter's global `imageCache`, so the
  /// handle is cloned before the [ImageInfo] is released: the clone is ours
  /// to [dispose] and the cache entry stays intact.
  ///
  /// The provider's `scale` is deliberately ignored: [width]/[height] report
  /// raw decoded pixels, so a 2x asset variant loads at twice the size rather
  /// than silently drawing at the same logical size.
  static Future<ui.Image> _resolveProvider(ImageProvider provider) {
    final completer = Completer<ui.Image>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (ImageInfo info, bool synchronousCall) {
        if (!completer.isCompleted) completer.complete(info.image.clone());
        info.dispose();
        stream.removeListener(listener);
      },
      onError: (Object error, StackTrace? stack) {
        if (!completer.isCompleted) {
          completer.completeError(
            FlutterError('loadImage() failed for $provider: $error'),
            stack,
          );
        }
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  // ── Resize ────────────────────────────────────────────────────────────

  /// Paint used to resample the bitmap during [resize]. Shared and never
  /// mutated — one resample setting for every resize.
  static final Paint _resamplePaint = Paint()
    ..filterQuality = FilterQuality.medium
    ..isAntiAlias = true;

  /// Resizes this image to [width] × [height] pixels, in place.
  ///
  /// Destructive, exactly like p5's `img.resize()`: the old bitmap is
  /// released and every later `image()` call draws the new one. Downscaling
  /// discards detail permanently — reload the file if you need it back.
  ///
  /// Loaded [pixels] are discarded, since they no longer match the bitmap's
  /// size: `await loadPixels()` again to read the resized image.
  ///
  /// Passing `0` for one dimension derives it from the other so the aspect
  /// ratio is preserved:
  ///
  /// ```dart
  /// logo.resize(200, 0);  // 200 wide, height follows
  /// logo.resize(0, 120);  // 120 tall, width follows
  /// ```
  ///
  /// Resizing once at load time is much cheaper than drawing an oversized
  /// bitmap scaled down every frame — a 4000px photo shown at 300px resamples
  /// 178× more pixels per frame than it needs to.
  void resize(int width, int height) {
    if (_disposed) {
      Flut5Console.printLater(
        'resize() ignored: the image loaded from "$source" was disposed.',
      );
      return;
    }
    final srcW = _image.width;
    final srcH = _image.height;
    if (srcW <= 0 || srcH <= 0) return;

    int targetW = width;
    int targetH = height;
    if (targetW <= 0 && targetH <= 0) {
      Flut5Console.printLater(
        'resize() ignored: pass a positive width, a positive height, or one '
        'of each. A 0 is only allowed for the dimension you want derived '
        'from the aspect ratio.',
      );
      return;
    }
    if (targetW <= 0) targetW = (srcW * (targetH / srcH)).round();
    if (targetH <= 0) targetH = (srcH * (targetW / srcW)).round();
    if (targetW < 1) targetW = 1;
    if (targetH < 1) targetH = 1;
    if (targetW == srcW && targetH == srcH) return;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      _image,
      Rect.fromLTWH(0, 0, srcW.toDouble(), srcH.toDouble()),
      Rect.fromLTWH(0, 0, targetW.toDouble(), targetH.toDouble()),
      _resamplePaint,
    );
    final picture = recorder.endRecording();
    final resized = picture.toImageSync(targetW, targetH);
    picture.dispose();
    // The CPU copy was the old size and can't be resampled to match the GPU
    // result exactly — drop it; `loadPixels()` reads the new bitmap.
    _pixels = null;
    _uploader?.releaseScratch();
    _replaceBitmap(resized);
  }

  /// Swaps in [next] as this image's bitmap. The old handle is freed once no
  /// render queue still holds it — an `image()` queued earlier in the same
  /// frame keeps painting the bitmap it was given.
  void _replaceBitmap(ui.Image next) {
    Flut5ImageHandles.disposeWhenReleased(_image);
    _image = next;
    _bitmapVersion++;
  }

  // ── Region copy ───────────────────────────────────────────────────────

  /// Copies the pixels inside this paint's source rect 1:1 — no blending and
  /// no filtering, so every byte comes across unchanged.
  static final Paint _copyPaint = Paint()
    ..blendMode = BlendMode.src
    ..filterQuality = FilterQuality.none
    ..isAntiAlias = false;

  /// A new [width]×[height] image holding the pixels of this one whose
  /// top-left corner is at ([x], [y]).
  ///
  /// p5's region form of `img.get(x, y, w, h)` — a separate method here
  /// because Dart can't give one `get` two return types, and [get] returns
  /// a [Color]:
  ///
  /// ```dart
  /// final tile = sheet.getRegion(32, 0, 32, 32);  // 2nd tile, top row
  /// image(tile, 10, 10);
  /// ```
  ///
  /// The copy is exact and made on the GPU, so it is synchronous and needs no
  /// [loadPixels]. It copies the bitmap as last drawn, so [set] or [pixels]
  /// edits not yet pushed with [updatePixels] aren't in it. The result is
  /// independent: editing, resizing or disposing either image leaves the
  /// other alone. Its own [pixels] need [loadPixels], as for any new image.
  ///
  /// Any part of the region past the edge comes out transparent, as in p5.
  /// Fractional [x]/[y] pick the pixel they fall in. Throws a [RangeError]
  /// for a [width] or [height] below 1.
  ///
  /// To *draw* part of an image, `image()`'s sprite-sheet form needs no copy;
  /// reach for this when the piece should be an image of its own.
  Flut5Image getRegion(num x, num y, int width, int height) {
    _checkExtent(width, height);
    final label = 'region ($x, $y, $width×$height) of $source';
    if (_disposed) {
      Flut5Console.printLater(
        'getRegion() returned a transparent image: the image from "$source" '
        'was disposed.',
      );
      return Flut5Image._(_paintBitmap(width, height, null), label);
    }
    final left = x.isFinite ? x.floor() : 0;
    final top = y.isFinite ? y.floor() : 0;
    final region = Rect.fromLTWH(
      left.toDouble(),
      top.toDouble(),
      width.toDouble(),
      height.toDouble(),
    );
    final inside = region.intersect(
      Rect.fromLTWH(0, 0, _image.width.toDouble(), _image.height.toDouble()),
    );
    final original = _image;
    final bitmap = _paintBitmap(
      width,
      height,
      inside.width <= 0 || inside.height <= 0
          ? null
          : (canvas) => canvas.drawImageRect(
              original,
              inside,
              inside.shift(Offset(-region.left, -region.top)),
              _copyPaint,
            ),
    );
    return Flut5Image._(bitmap, label);
  }

  // ── Pixels ────────────────────────────────────────────────────────────

  /// CPU copy of the bitmap, straight-alpha RGBA. `null` until [loadPixels]
  /// completes (set from the start by [Flut5Image.create]), and again after
  /// [resize] or [dispose].
  Uint8ClampedList? _pixels;

  /// What [pixels] returns before [loadPixels] — p5's `pixels` is likewise
  /// an empty array until loaded.
  static final Uint8ClampedList _noPixels = Uint8ClampedList(0);

  /// Bumped whenever [_image] is replaced, so a [loadPixels] read that was
  /// in flight across a [resize] or [updatePixels] can tell it is stale.
  int _bitmapVersion = 0;

  /// Created by the first [updatePixels]; keeps the upload scratch buffer.
  Flut5PixelUploader? _uploader;

  /// The image's pixels as a flat list of bytes — red, green, blue, alpha
  /// for the top-left pixel, then the next one along the row, row after row:
  ///
  /// ```dart
  /// final i = (x + y * img.width) * 4;
  /// final r = img.pixels[i];
  /// final g = img.pixels[i + 1];
  /// final b = img.pixels[i + 2];
  /// final a = img.pixels[i + 3];
  /// ```
  ///
  /// p5's `img.pixels`, with the same layout. Empty until [loadPixels]
  /// completes (reading it then warns, since a forgotten `await` is the
  /// usual cause) — except for an image from `createImage()`, whose pixels
  /// are ready at once. Colours are straight, not premultiplied: setting alpha
  /// leaves red, green and blue as written. Writes clamp to 0–255, like p5's
  /// `Uint8ClampedArray`.
  ///
  /// Editing the list changes nothing on screen until [updatePixels].
  ///
  /// The same list object is kept across [loadPixels] and [updatePixels]
  /// calls, so holding on to it is fine — until [resize] or [dispose], which
  /// discard it.
  Uint8ClampedList get pixels =>
      _loadedPixelsOrWarn('pixels is empty') ?? _noPixels;

  /// [_pixels], or `null` after queueing a warning that starts with
  /// [outcome] and says how to load them.
  Uint8ClampedList? _loadedPixelsOrWarn(String outcome) {
    final loaded = _pixels;
    if (loaded != null) return loaded;
    Flut5Console.printLater(
      _disposed
          ? '$outcome: the image from "$source" was disposed.'
          : '$outcome: no pixels are loaded for the image from "$source". '
                '`await img.loadPixels()` first (in setup(), for example); '
                'resize() also discards them.',
    );
    return null;
  }

  /// Reads this image's bitmap into [pixels].
  ///
  /// p5's `img.loadPixels()` — of this image, not of the canvas. Unlike p5's
  /// it returns a [Future]: the bitmap lives on the GPU and Flutter can only
  /// read it back asynchronously. Await it, typically in `setup()`:
  ///
  /// ```dart
  /// late final Flut5Image photo;
  ///
  /// @override
  /// Future<void> setup() async {
  ///   photo = await loadImage('photo.jpg');
  ///   await photo.loadPixels();
  ///   for (var y = 0; y < photo.height; y++) {
  ///     for (var x = 0; x < photo.width; x++) {
  ///       final i = (x + y * photo.width) * 4;
  ///       photo.pixels[i] = 255 - photo.pixels[i];  // invert red
  ///     }
  ///   }
  ///   photo.updatePixels();
  /// }
  /// ```
  ///
  /// Overwrites unsaved edits to [pixels] — call it once, then edit and
  /// [updatePixels] as often as you like; the list stays in step with the
  /// bitmap. It only needs calling again after [resize], and an image from
  /// `createImage()` doesn't need it at all.
  ///
  /// The read is a GPU-to-CPU copy of the whole image, so keep it out of
  /// per-frame code. Fully transparent pixels read back as `0, 0, 0, 0`, and
  /// translucent ones may come back a level or two off: bitmaps are stored
  /// premultiplied, so a colour at alpha 10 has only 11 distinct levels per
  /// channel. p5 behaves the same way.
  Future<void> loadPixels() async {
    while (true) {
      if (_disposed) {
        Flut5Console.printLater(
          'loadPixels() ignored: the image loaded from "$source" was disposed.',
        );
        return;
      }
      final version = _bitmapVersion;
      // Our own handle, so a resize() or dispose() during the read can't free
      // the bitmap out from under it.
      final snapshot = _image.clone();
      final ByteData? bytes;
      try {
        bytes = await snapshot.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
      } finally {
        snapshot.dispose();
      }
      if (_disposed) return;
      if (version != _bitmapVersion) {
        // Replaced mid-read. updatePixels() leaves [pixels] matching the new
        // bitmap already; resize() discarded them, so read the new one.
        if (_pixels != null) return;
        continue;
      }
      if (bytes == null) {
        throw FlutterError(
          'loadPixels() could not read the image loaded from "$source".',
        );
      }
      final fresh = bytes.buffer.asUint8ClampedList(
        bytes.offsetInBytes,
        bytes.lengthInBytes,
      );
      final current = _pixels;
      if (current != null && current.length == fresh.length) {
        current.setAll(0, fresh);
      } else {
        _pixels = fresh;
      }
      return;
    }
  }

  /// Writes [pixels] back into the bitmap, so the next `image()` draws the
  /// edits.
  ///
  /// p5's `img.updatePixels()`. Synchronous: an `image()` call right after it
  /// draws the new pixels, even in the same `draw()`. Draws queued *before*
  /// it keep the old bitmap, so one image can be drawn, edited and drawn
  /// again within a frame.
  ///
  /// Every call uploads the whole image, so per-frame updates suit small
  /// images. On Impeller (iOS, macOS, Android) the upload is direct; on Skia
  /// and the web it falls back to drawing each pixel as a sprite, which is
  /// slower and needs more memory while it runs.
  ///
  /// Requires loaded pixels — call [loadPixels] first.
  void updatePixels() {
    final straightRgba = _loadedPixelsOrWarn('updatePixels() ignored');
    if (straightRgba == null) return;
    final uploader = _uploader ??= Flut5PixelUploader();
    _replaceBitmap(uploader.upload(straightRgba, _image.width, _image.height));
  }

  static const Color _transparentBlack = Color(0x00000000);

  /// The colour of the pixel at ([x], [y]).
  ///
  /// p5's `img.get(x, y)`. It reads [pixels], so it needs them loaded —
  /// `await loadPixels()` first, except for an image from `createImage()` —
  /// and it sees [set] edits before [updatePixels] has pushed them.
  ///
  /// ```dart
  /// await photo.loadPixels();
  /// // ...
  /// fill(photo.get(mouseX, mouseY));  // colour under the mouse
  /// ```
  ///
  /// Fractional coordinates pick the pixel they fall in, so `mouseX`-style
  /// doubles work directly. Outside the image it returns transparent black,
  /// as p5 does; before pixels are loaded it does too, with a warning.
  ///
  /// For whole-image loops, reading [pixels] directly avoids building a
  /// [Color] per pixel. To copy a rectangle of pixels out as a new image,
  /// use [getRegion].
  Color get(num x, num y) {
    final loaded = _loadedPixelsOrWarn('get() returned transparent');
    if (loaded == null) return _transparentBlack;
    final offset = _pixelOffset(x, y);
    if (offset < 0) return _transparentBlack;
    return Color.fromARGB(
      loaded[offset + 3],
      loaded[offset],
      loaded[offset + 1],
      loaded[offset + 2],
    );
  }

  /// Sets the pixel at ([x], [y]) to [color].
  ///
  /// p5's `img.set(x, y, color)`. Like editing [pixels] by hand, nothing
  /// changes on screen until [updatePixels] — set as many pixels as you like,
  /// then update once:
  ///
  /// ```dart
  /// final noise = createImage(64, 64);
  /// for (var y = 0; y < 64; y++) {
  ///   for (var x = 0; x < 64; x++) {
  ///     noise.set(x, y, random(1) < 0.5 ? Colors.black : Colors.white);
  ///   }
  /// }
  /// noise.updatePixels();
  /// ```
  ///
  /// The pixel is replaced, alpha included, not blended over. Needs loaded
  /// pixels, like [get]. Fractional coordinates pick the pixel they fall in;
  /// a pixel outside the image is ignored, as in p5. A colour in another
  /// colour space (Display P3) is converted to sRGB, clamping whatever sRGB
  /// can't show.
  void set(num x, num y, Color color) {
    final loaded = _loadedPixelsOrWarn('set() ignored');
    if (loaded == null) return;
    final offset = _pixelOffset(x, y);
    if (offset < 0) return;
    final srgb = color.colorSpace == ui.ColorSpace.sRGB
        ? color
        : color.withValues(colorSpace: ui.ColorSpace.sRGB);
    final argb = srgb.toARGB32();
    loaded[offset] = (argb >> 16) & 0xFF;
    loaded[offset + 1] = (argb >> 8) & 0xFF;
    loaded[offset + 2] = argb & 0xFF;
    loaded[offset + 3] = argb >> 24;
  }

  /// Byte offset of pixel ([x], [y]) in [pixels], or -1 outside the image.
  /// Coordinates are floored to the pixel they fall in.
  int _pixelOffset(num x, num y) {
    if (!x.isFinite || !y.isFinite) return -1;
    final column = x.floor();
    final row = y.floor();
    final imageWidth = width;
    if (column < 0 || row < 0 || column >= imageWidth || row >= height) {
      return -1;
    }
    return (column + row * imageWidth) * 4;
  }

  // ── Lifetime ──────────────────────────────────────────────────────────

  /// Releases the decoded bitmap. Idempotent.
  ///
  /// Call it when a sketch drops an image it will not draw again — for a
  /// fixed set of images loaded in `setup()` and kept for the sketch's
  /// lifetime, it is unnecessary. Drawing after disposal warns and draws
  /// nothing rather than crashing. Draws already queued this frame still
  /// paint: the bitmap is freed once they have.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pixels = null;
    _uploader = null;
    Flut5ImageHandles.disposeWhenReleased(_image);
  }

  @override
  String toString() =>
      'Flut5Image($source, ${width}x$height${_disposed ? ', disposed' : ''})';
}
