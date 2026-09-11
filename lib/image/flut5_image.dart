import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;

import '../core/flut5_console.dart';

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
/// `image(img, x, y)`; reshape it in place with [resize].
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

  bool _disposed = false;

  /// The decoded bitmap. Valid until [dispose]; replaced by [resize].
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
    _image.dispose();
    _image = resized;
  }

  // ── Lifetime ──────────────────────────────────────────────────────────

  /// Releases the decoded bitmap. Idempotent.
  ///
  /// Call it when a sketch drops an image it will not draw again — for a
  /// fixed set of images loaded in `setup()` and kept for the sketch's
  /// lifetime, it is unnecessary. Drawing after disposal warns and draws
  /// nothing rather than crashing.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _image.dispose();
  }

  @override
  String toString() =>
      'Flut5Image($source, ${width}x$height${_disposed ? ', disposed' : ''})';
}
