// The render queue hands each batch a Path and takes them all back in
// clear(), to reuse next frame. These tests pin the two things that makes
// safe: a frame already recorded keeps its own outlines, and paths from a
// one-off busy frame are let go.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flut5/flut5.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const int _size = 120;

/// One batch per shape: every shape has its own colour.
void _drawFrame(Flut5Engine e, int shapes, double offset) {
  e.noStroke();
  for (var i = 0; i < shapes; i++) {
    e.fill(Color.fromARGB(255, 40 + i * 7 % 200, 255 - i * 11 % 200, i * 5));
    final x = offset + (i % 10) * 11.0, y = offset + (i ~/ 10) * 11.0;
    switch (i % 3) {
      case 0:
        e.rect(x, y, 8, 8);
      case 1:
        e.circle(x + 4, y + 4, 9);
      default:
        e.triangle(x, y + 8, x + 4, y, x + 8, y + 8);
    }
  }
}

ui.Picture _record(Flut5Engine e) {
  final recorder = ui.PictureRecorder();
  e.renderQueue.execute(Canvas(recorder));
  return recorder.endRecording();
}

Future<Uint8List> _pixels(ui.Picture picture) async {
  final image = await picture.toImage(_size, _size);
  final bytes = (await image.toByteData())!.buffer.asUint8List();
  image.dispose();
  return bytes;
}

List<Path> _batchPaths(Flut5Engine e) {
  e.renderQueue.flushPending();
  return [
    for (final item in e.renderQueue.items)
      if (item is PathRenderItem) item.path,
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a recorded frame keeps its outlines when its paths are reused',
    () async {
      final reused = Flut5Engine();
      _drawFrame(reused, 40, 0);
      final firstFrame = _record(reused);
      reused.renderQueue.clear();
      // The second frame rewrites every path the first one drew from.
      _drawFrame(reused, 70, 3.5);
      final secondFrame = _record(reused);
      reused.renderQueue.clear();

      final fresh = Flut5Engine();
      _drawFrame(fresh, 40, 0);
      final firstExpected = _record(fresh);
      final other = Flut5Engine();
      _drawFrame(other, 70, 3.5);
      final secondExpected = _record(other);

      expect(await _pixels(firstFrame), await _pixels(firstExpected));
      expect(await _pixels(secondFrame), await _pixels(secondExpected));
      expect(await _pixels(firstFrame), isNot(await _pixels(secondFrame)));
    },
  );

  test('the next frame draws from the same paths', () {
    final e = Flut5Engine();
    _drawFrame(e, 30, 0);
    final first = _batchPaths(e);
    expect(first, hasLength(30));
    e.renderQueue.clear();

    _drawFrame(e, 50, 2);
    final second = _batchPaths(e);
    expect(second, hasLength(50));
    for (var i = 0; i < 30; i++) {
      expect(identical(second[i], first[i]), isTrue);
    }
    expect(second.toSet(), hasLength(50));
  });

  test('paths from one busy frame are let go after a while', () {
    final e = Flut5Engine();
    _drawFrame(e, 80, 0);
    final busy = _batchPaths(e);
    e.renderQueue.clear();
    for (var frame = 0; frame < 300; frame++) {
      _drawFrame(e, 5, 0);
      e.renderQueue.flushPending();
      e.renderQueue.clear();
    }
    _drawFrame(e, 80, 0);
    final later = _batchPaths(e);
    expect(identical(later[0], busy[0]), isTrue);
    expect(identical(later[4], busy[4]), isTrue);
    expect(identical(later[40], busy[40]), isFalse);
  });
}
