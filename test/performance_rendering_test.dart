import 'dart:ui' as ui;

import 'package:flut5/flut5.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('scratch paths and matrices cannot mutate retained geometry', () async {
    final e = Flut5Engine()
      ..fill(Colors.white)
      ..noStroke();
    e.push();
    e.translate(40, 40);
    e.rotate(.3);
    e.scale(1.4);
    e.ellipse(0, 0, 18, 10);
    e.rect(20, 0, 12, 8, 3);
    e.arc(0, 25, 14, 10, 0, 2);
    e.pop();
    e.renderQueue.flushPending();
    final retained = e.renderQueue.items.toList();
    Future<List<int>> render() async {
      final r = ui.PictureRecorder();
      final c = Canvas(r);
      for (final item in retained) {
        item.execute(c);
      }
      final p = r.endRecording();
      final image = await p.toImage(120, 120);
      final data = await image.toByteData();
      image.dispose();
      p.dispose();
      return data!.buffer.asUint8List();
    }

    final before = await render();
    e.renderQueue.clear();
    e.rotate(2);
    e.scale(4);
    e.ellipse(90, 90, 80, 40);
    e.rect(0, 0, 100, 80, 4);
    e.renderQueue.flushPending();
    expect(await render(), before);
  });

  test(
    'gradient text retains fill stroke spacing alignment and clipping',
    () async {
      final cache = Flut5TextCache.instance;
      cache.clear();
      addTearDown(cache.clear);
      final r = ui.PictureRecorder();
      final c = Canvas(r)..drawColor(Colors.white, BlendMode.src);
      for (var i = 0; i < 6; i++) {
        c.save();
        c.translate(15, 10 + i * 58.0);
        c.rotate(.02);
        TextDynamicRenderItem(
          text: 'AV Hello  World\nSecond line',
          x: 180,
          y: 0,
          maxWidth: i.isEven ? null : 240,
          maxHeight: 54,
          fontFamily: 'sans-serif',
          fontSize: 18,
          fontWeight: FontWeight.normal,
          fontStyle: FontStyle.italic,
          textAlign: TextAlign.values[i % 3],
          textLeading: 1.2,
          letterSpacing: (i - 2) * 1.1,
          fillPaint: i == 3 ? null : (Paint()..color = Colors.red),
          strokePaint: i == 0 ? null : (Paint()..strokeWidth = 1 + i * .2),
          fillGradient: i == 3
              ? null
              : const LinearGradient(colors: [Colors.red, Colors.blue]),
          strokeGradient: i == 0
              ? null
              : const LinearGradient(colors: [Colors.green, Colors.orange]),
          shadow: i > 3
              ? Flut5ShadowSpec(
                  const Color(0x88000000),
                  const Offset(2, 3),
                  2,
                  0,
                )
              : null,
        ).execute(c);
        c.restore();
      }
      final p = r.endRecording();
      final image = await p.toImage(640, 380);
      p.dispose();
      addTearDown(image.dispose);
      await expectLater(
        image,
        matchesGoldenFile('goldens/performance_gradient_text.png'),
      );
    },
  );
}
