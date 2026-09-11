import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'package:flut5/flut5.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;
import 'package:flut5/text/flut5_font_variation.dart';
import 'package:flut5/text/flut5_gvar_decoder.dart';

void main() {
  test('Engine initializes correctly', () {
    final engine = Flut5Engine();
    expect(engine.width, 0.0);
    expect(engine.height, 0.0);
    expect(engine.size, Size.zero);
    expect(engine.environment.width, 0.0);
    expect(engine.environment.height, 0.0);
    expect(engine.mouseX, 0.0);
    expect(engine.mouseY, 0.0);
    expect(engine.pmouseX, 0.0);
    expect(engine.pmouseY, 0.0);
    expect(engine.key, '');
    expect(engine.keyCode, 0);
    expect(engine.environment.frameCount, 0);
    expect(engine.environment.deltaTime, 0.0);
  });

  group('Flut5RenderQueue.contentBoundsFrom (container overscroll bounds)', () {
    Paint fill() => Paint()..color = const Color(0xFF000000);

    test('returns null when no measurable content was drawn', () {
      final queue = Flut5RenderQueue();
      expect(queue.contentBoundsFrom(0), isNull);
    });

    test('unions geometry at negative and overflowing coordinates', () {
      final queue = Flut5RenderQueue();
      // A shape spilling past the top-left into negative space…
      queue.enqueue(
        RectRenderItem(
          const Rect.fromLTWH(-20, -30, 10, 10),
          null,
          fill(),
          null,
        ),
      );
      // …and another well past a 100×100 container's bottom-right.
      queue.enqueue(
        RectRenderItem(
          const Rect.fromLTWH(140, 160, 10, 10),
          null,
          fill(),
          null,
        ),
      );
      queue.flushPending();

      expect(
        queue.contentBoundsFrom(0),
        const Rect.fromLTRB(-20, -30, 150, 170),
      );
    });

    test('is transform-aware and restores the matrix after pop', () {
      final queue = Flut5RenderQueue();
      // Content moved by a nested push/translate/pop…
      queue.enqueue(TransformRenderItem.push());
      queue.enqueue(TransformRenderItem.translate(100, 50));
      queue.enqueue(
        RectRenderItem(const Rect.fromLTWH(0, 0, 10, 10), null, fill(), null),
      );
      queue.enqueue(TransformRenderItem.pop());
      // …and content drawn back at the origin after the pop.
      queue.enqueue(CircleRenderItem(const Offset(2, 2), 2, fill(), null));
      queue.flushPending();

      // Translated rect → (100,50)-(110,60); circle → (0,0)-(4,4).
      expect(queue.contentBoundsFrom(0), const Rect.fromLTRB(0, 0, 110, 60));
    });

    test('measures only items from the start index onward', () {
      final queue = Flut5RenderQueue();
      queue.enqueue(
        RectRenderItem(const Rect.fromLTWH(0, 0, 500, 500), null, fill(), null),
      );
      queue.flushPending();
      final slot = queue.itemCount;
      queue.enqueue(
        RectRenderItem(const Rect.fromLTWH(10, 10, 20, 20), null, fill(), null),
      );
      queue.flushPending();

      expect(
        queue.contentBoundsFrom(slot),
        const Rect.fromLTRB(10, 10, 30, 30),
      );
    });
  });

  group('Flut5RenderQueue clip / save-stack balance', () {
    Canvas recordingCanvas() => Canvas(ui.PictureRecorder());

    test('clip does not save on its own — push/clip/pop balances', () {
      final queue = Flut5RenderQueue();
      // Mirror the documented pattern: push(); clipRect(); ...; pop();
      queue.enqueue(TransformRenderItem.push());
      queue.enqueue(ClipRenderItem.rect(const Rect.fromLTWH(0, 0, 50, 50)));
      queue.enqueue(TransformRenderItem.pop());

      final canvas = recordingCanvas();
      final baseline = canvas.getSaveCount();
      queue.execute(canvas);
      // pop() restored the push()'s save and lifted the clip — no leak.
      expect(canvas.getSaveCount(), baseline);
    });

    test('a bare clip with no enclosing push leaks no save', () {
      final queue = Flut5RenderQueue();
      queue.enqueue(ClipRenderItem.rect(const Rect.fromLTWH(0, 0, 50, 50)));

      final canvas = recordingCanvas();
      final baseline = canvas.getSaveCount();
      queue.execute(canvas);
      // The clip narrows the current layer but adds no save() of its own.
      expect(canvas.getSaveCount(), baseline);
    });
  });

  group('beginLayout / endLayout container flow', () {
    // Alignment shifts are applied by patching the per-container placeholder
    // translate, so they are observed as translate items in the queue.
    List<Offset> translatesIn(Flut5Engine engine) {
      engine.renderQueue.flushPending();
      return engine.renderQueue.items
          .whereType<TransformRenderItem>()
          .where((t) => t.type == TransformType.translate)
          .map((t) => Offset(t.dx!, t.dy!))
          .toList();
    }

    test('horizontal layout stacks containers left to right with the gap', () {
      final engine = Flut5Engine();
      engine.layoutDirection(Flut5LayoutDirection.horizontal);
      engine.layoutGap(10);
      engine.beginLayout();

      engine.beginContainer(100, 60);
      expect(engine.containerContext!.x, 0);
      expect(engine.containerContext!.y, 0);
      engine.endContainer();

      engine.beginContainer(80, 40);
      expect(engine.containerContext!.x, 110); // 100 + 10 gap
      expect(engine.containerContext!.y, 0);
      engine.endContainer();

      engine.beginContainer(20, 20);
      expect(engine.containerContext!.x, 200); // 110 + 80 + 10 gap
      engine.endContainer();

      engine.endLayout();
      expect(engine.containerContext, isNull);
    });

    test('vertical layout stacks containers top to bottom', () {
      final engine = Flut5Engine();
      engine.layoutDirection(Flut5LayoutDirection.vertical);
      engine.layoutGap(4);
      engine.beginLayout();

      engine.beginContainer(100, 60);
      expect(engine.containerContext!.y, 0);
      engine.endContainer();

      engine.beginContainer(100, 30);
      expect(engine.containerContext!.x, 0);
      expect(engine.containerContext!.y, 64); // 60 + 4 gap
      engine.endContainer();

      engine.endLayout();
    });

    test('nested containers flow inside their parent', () {
      final engine = Flut5Engine();
      // Root flows horizontally; the container opened next flows its own
      // children vertically (snapshot rule: set before beginContainer).
      engine.layoutDirection(Flut5LayoutDirection.horizontal);
      engine.layoutGap(0);
      engine.beginLayout();

      engine.layoutDirection(Flut5LayoutDirection.vertical);
      engine.layoutGap(5);
      engine.beginContainer(200, 100); // placed by the root frame at (0, 0)
      expect(engine.containerContext!.x, 0);

      engine.beginContainer(50, 20);
      expect(engine.containerContext!.y, 0);
      engine.endContainer();

      engine.beginContainer(50, 20);
      expect(engine.containerContext!.x, 0);
      expect(engine.containerContext!.y, 25); // 20 + 5 gap
      engine.endContainer();

      engine.endContainer();

      // Sibling of the outer container: the root frame snapshotted
      // horizontal / gap 0 before beginLayout(), so it lands at x = 200.
      engine.beginContainer(80, 40);
      expect(engine.containerContext!.x, 200);
      expect(engine.containerContext!.y, 0);
      engine.endContainer();

      engine.endLayout();
    });

    test('args map is accepted in the layout form', () {
      final engine = Flut5Engine();
      engine.beginLayout();
      engine.beginContainer(100, 60, {'borderRadius': 12, 'id': 'a'});
      expect(engine.containerContext!.width, 100);
      expect(engine.containerContext!.height, 60);
      engine.endContainer();
      engine.endLayout();
    });

    test('positioned form is unchanged outside a layout', () {
      final engine = Flut5Engine();
      engine.beginContainer(20, 30, 100, 60);
      expect(engine.containerContext!.x, 20);
      expect(engine.containerContext!.y, 30);
      expect(engine.containerContext!.width, 100);
      expect(engine.containerContext!.height, 60);
      engine.endContainer();
    });

    test('endLayout force-closes containers left open inside the layout', () {
      final engine = Flut5Engine();
      engine.beginLayout();
      engine.beginContainer(100, 60);
      engine.endLayout(); // missing endContainer()
      expect(engine.containerContext, isNull);

      // The layout is fully closed: a new positioned container works normally.
      engine.beginContainer(5, 6, 10, 10);
      expect(engine.containerContext!.x, 5);
      engine.endContainer();
    });

    test('closeUnbalancedLayouts clears layouts left open at frame end', () {
      final engine = Flut5Engine();
      engine.beginLayout();
      engine.beginContainer(100, 60);
      engine.closeUnbalancedLayouts();
      engine.closeUnbalancedContainers();
      expect(engine.containerContext, isNull);

      engine.beginContainer(5, 6, 10, 10);
      expect(engine.containerContext!.x, 5);
      engine.endContainer();
    });

    test('a stray endContainer inside a layout cannot close an outer '
        'container', () {
      final engine = Flut5Engine();
      engine.beginContainer(5, 5, 300, 300); // absolute, outside the layout
      engine.beginLayout();

      engine.beginContainer(50, 20);
      engine.endContainer();
      engine.endContainer(); // unbalanced pair — warned and ignored

      engine.endLayout();

      // The absolute container survived the stray call and closes normally.
      expect(engine.containerContext, isNotNull);
      expect(engine.containerContext!.x, 5);
      engine.endContainer();
      expect(engine.containerContext, isNull);
    });

    test('frame cleanup closes an open layout nested in an open container', () {
      final engine = Flut5Engine();
      engine.beginContainer(5, 6, 100, 100);
      engine.beginLayout();
      // Painter order: layouts first, then containers.
      engine.closeUnbalancedLayouts();
      engine.closeUnbalancedContainers();
      expect(engine.containerContext, isNull);

      engine.beginContainer(5, 6, 10, 10);
      expect(engine.containerContext!.x, 5);
      engine.endContainer();
    });

    test('layoutWrap wraps containers at the layout bounds', () {
      final engine = Flut5Engine();
      engine.layoutDirection(Flut5LayoutDirection.horizontal);
      engine.layoutGap(10);
      engine.layoutWrap(Flut5LayoutWrap.wrap);
      engine.beginLayout(0, 0, 250, 200);

      engine.beginContainer(100, 30);
      expect(engine.containerContext!.x, 0);
      expect(engine.containerContext!.y, 0);
      engine.endContainer();

      engine.beginContainer(100, 50);
      expect(engine.containerContext!.x, 110);
      expect(engine.containerContext!.y, 0);
      engine.endContainer();

      // 220 + 100 > 250 → new line, below the tallest container (50) + gap.
      engine.beginContainer(100, 20);
      expect(engine.containerContext!.x, 0);
      expect(engine.containerContext!.y, 60);
      engine.endContainer();

      engine.endLayout();
    });

    test('layoutGap crossGap spaces wrapped lines independently', () {
      final engine = Flut5Engine();
      engine.layoutGap(10, 3);
      engine.layoutWrap(Flut5LayoutWrap.wrap);
      engine.beginLayout(0, 0, 250, 200);

      engine.beginContainer(100, 30);
      engine.endContainer();
      engine.beginContainer(100, 30);
      engine.endContainer();
      engine.beginContainer(100, 30); // wraps: 30 line + 3 cross gap
      expect(engine.containerContext!.y, 33);
      engine.endContainer();

      engine.endLayout();
    });

    test('wrapReverse stacks lines from the cross-axis end', () {
      final engine = Flut5Engine();
      engine.layoutGap(10);
      engine.layoutWrap(Flut5LayoutWrap.wrapReverse);
      engine.beginLayout(0, 0, 250, 200);

      engine.beginContainer(100, 30); // bottom edge: 200 - 30
      expect(engine.containerContext!.y, 170);
      engine.endContainer();

      engine.beginContainer(100, 50);
      expect(engine.containerContext!.x, 110);
      expect(engine.containerContext!.y, 150);
      engine.endContainer();

      // Wraps: the next line sits above the first (50 line + 10 cross gap).
      engine.beginContainer(100, 20);
      expect(engine.containerContext!.x, 0);
      expect(engine.containerContext!.y, 120); // 200 - 60 - 20
      engine.endContainer();

      engine.endLayout();
    });

    test('layoutPadding insets children and shrinks the wrap limit', () {
      final engine = Flut5Engine();
      engine.layoutGap(0);
      engine.layoutWrap(Flut5LayoutWrap.wrap);
      engine.layoutPadding(const EdgeInsets.fromLTRB(20, 10, 30, 0));
      engine.beginLayout(0, 0, 250, 200); // content box: 250 - 20 - 30 = 200

      engine.beginContainer(100, 40);
      expect(engine.containerContext!.x, 20);
      expect(engine.containerContext!.y, 10);
      engine.endContainer();

      engine.beginContainer(100, 40);
      expect(engine.containerContext!.x, 120);
      engine.endContainer();

      // 200 + 100 > 200 content width → wraps below the 40-tall line.
      engine.beginContainer(100, 40);
      expect(engine.containerContext!.x, 20);
      expect(engine.containerContext!.y, 50);
      engine.endContainer();

      engine.endLayout();
    });

    test('root layout wraps at the canvas edge when no bounds are given', () {
      final engine = Flut5Engine();
      engine.environment = const SketchEnvironment().withSize(
        const Size(250, 400),
      );
      engine.layoutGap(10);
      engine.layoutWrap(Flut5LayoutWrap.wrap);
      engine.beginLayout();

      engine.beginContainer(100, 30);
      engine.endContainer();
      engine.beginContainer(100, 30);
      engine.endContainer();
      engine.beginContainer(100, 30); // 220 + 100 > 250 canvas width
      expect(engine.containerContext!.x, 0);
      expect(engine.containerContext!.y, 40);
      engine.endContainer();

      engine.endLayout();
    });

    test('a layout inside a container takes its bounds from the container', () {
      // Canvas is 0-sized here, so these bounds can only come from the
      // enclosing absolute container.
      final engine = Flut5Engine();
      engine.layoutGap(10);
      engine.layoutWrap(Flut5LayoutWrap.wrap);
      engine.beginContainer(20, 20, 250, 300);
      engine.beginLayout();

      engine.beginContainer(100, 30);
      engine.endContainer();
      engine.beginContainer(100, 30);
      engine.endContainer();
      engine.beginContainer(100, 30); // 220 + 100 > 250 container width
      expect(engine.containerContext!.x, 0);
      expect(engine.containerContext!.y, 40);
      engine.endContainer();

      engine.endLayout();
      engine.endContainer();

      // Justify also sees the container-derived limit.
      final justified = Flut5Engine();
      justified.layoutWrap(Flut5LayoutWrap.noWrap);
      justified.layoutGap(10);
      justified.layoutJustifyContent(Flut5LayoutJustify.end);
      justified.beginContainer(0, 0, 250, 100);
      justified.beginLayout();
      justified.beginContainer(100, 30);
      justified.endContainer();
      justified.beginContainer(100, 30);
      justified.endContainer();
      justified.endLayout();
      justified.endContainer();
      // Line content is 210 of 250 → both containers shift by the 40 free px.
      final shifts = translatesIn(justified)
          .where((o) => o == const Offset(40, 0));
      expect(shifts, hasLength(2));
    });

    test('beginLayout outside a container warns in the console', () {
      // Drain warnings queued by earlier tests before capturing output.
      Flut5Console.flush();
      final logs = <String>[];
      final prev = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = prev);

      final engine = Flut5Engine();
      engine.beginLayout(0, 0, 100, 100); // explicit bounds don't exempt it
      engine.endLayout();
      Flut5Console.flush();
      expect(
        logs.where((m) => m.contains('outside a container')),
        hasLength(1),
      );

      // Inside a container the same call is silent.
      logs.clear();
      engine.beginContainer(0, 0, 200, 200);
      engine.beginLayout();
      engine.endLayout();
      engine.endContainer();
      Flut5Console.flush();
      expect(logs.where((m) => m.contains('outside a container')), isEmpty);
    });

    test('nested containers wrap within their parent container', () {
      final engine = Flut5Engine();
      engine.layoutGap(0);
      engine.layoutWrap(Flut5LayoutWrap.wrap);
      engine.beginLayout(0, 0, 1000, 500);

      engine.beginContainer(120, 300);
      engine.beginContainer(50, 20);
      expect(engine.containerContext!.x, 0);
      engine.endContainer();
      engine.beginContainer(50, 20);
      expect(engine.containerContext!.x, 50);
      engine.endContainer();
      engine.beginContainer(50, 20); // 100 + 50 > 120 parent width
      expect(engine.containerContext!.x, 0);
      expect(engine.containerContext!.y, 20);
      engine.endContainer();
      engine.endContainer();

      engine.endLayout();
    });

    test('layoutAlignItems aligns shorter containers within their line', () {
      final engine = Flut5Engine();
      engine.layoutAlignItems(Flut5LayoutAlign.end);
      engine.beginLayout(0, 0, 400, 100);
      engine.beginContainer(100, 30); // line cross size is 50 → shift by 20
      engine.endContainer();
      engine.beginContainer(100, 50);
      engine.endContainer();
      engine.endLayout();
      expect(translatesIn(engine), contains(const Offset(0, 20)));

      final centered = Flut5Engine();
      centered.layoutAlignItems(Flut5LayoutAlign.center);
      centered.beginLayout(0, 0, 400, 100);
      centered.beginContainer(100, 30);
      centered.endContainer();
      centered.beginContainer(100, 50);
      centered.endContainer();
      centered.endLayout();
      expect(translatesIn(centered), contains(const Offset(0, 10)));
    });

    test('layoutJustifyContent distributes free main-axis space', () {
      final engine = Flut5Engine();
      engine.layoutGap(10);
      engine.layoutJustifyContent(Flut5LayoutJustify.center);
      engine.beginLayout(0, 0, 250, 100);
      engine.beginContainer(100, 30);
      engine.endContainer();
      engine.beginContainer(100, 30);
      engine.endContainer();
      engine.endLayout();
      // Line content is 210 of 250 → 40 free → both shift by 20.
      final shifts = translatesIn(engine)
          .where((o) => o == const Offset(20, 0));
      expect(shifts, hasLength(2));

      final between = Flut5Engine();
      between.layoutGap(10);
      between.layoutJustifyContent(Flut5LayoutJustify.spaceBetween);
      between.beginLayout(0, 0, 250, 100);
      between.beginContainer(100, 30);
      between.endContainer();
      between.beginContainer(100, 30);
      between.endContainer();
      between.endLayout();
      // First stays, second takes all 40 of free space.
      expect(translatesIn(between), contains(const Offset(40, 0)));
    });

    test('align/justify work in vertical direction (flex column)', () {
      final engine = Flut5Engine();
      engine.layoutDirection(Flut5LayoutDirection.vertical);
      engine.layoutAlignItems(Flut5LayoutAlign.end);
      engine.layoutJustifyContent(Flut5LayoutJustify.end);
      engine.beginLayout(0, 0, 150, 400);
      engine.beginContainer(100, 50); // line cross (width) is 100
      engine.endContainer();
      engine.beginContainer(80, 50); // 20 narrower → shifts right by 20
      engine.endContainer();
      engine.endLayout();
      // Main axis is y: content 100 of 400 → 300 free, packed at the end.
      final shifts = translatesIn(engine);
      expect(shifts, contains(const Offset(0, 300)));
      expect(shifts, contains(const Offset(20, 300)));
    });

    test('alignment is applied per wrapped line', () {
      final engine = Flut5Engine();
      engine.layoutGap(10);
      engine.layoutWrap(Flut5LayoutWrap.wrap);
      engine.layoutAlignItems(Flut5LayoutAlign.end);
      engine.beginLayout(0, 0, 250, 200);
      engine.beginContainer(100, 30); // line 1, cross 50 → shifts 20
      engine.endContainer();
      engine.beginContainer(100, 50);
      engine.endContainer();
      engine.beginContainer(100, 20); // line 2, alone → no shift
      engine.endContainer();
      engine.endLayout();
      final shifts = translatesIn(engine);
      expect(shifts, contains(const Offset(0, 20)));
      // Line 2's only container defines its line — no cross shift for it.
      expect(shifts, isNot(contains(const Offset(0, 180))));
    });

    test('one-time hint suggests visible overflow for clip-heavy frames', () {
      // Drain warnings queued by earlier tests before capturing output.
      Flut5Console.flush();
      final logs = <String>[];
      final prev = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = prev);

      // A frame's worth of visible containers never hints.
      final quiet = Flut5Engine();
      quiet.containerOverflow(Flut5ContainerOverflow.visible);
      for (var i = 0; i < 250; i++) {
        quiet.beginContainer(0, 0, 10, 10);
        quiet.endContainer();
      }
      Flut5Console.flush();
      expect(logs, isEmpty);

      // 200 clipping (default hidden) containers in one frame → one hint.
      final engine = Flut5Engine();
      for (var i = 0; i < 200; i++) {
        engine.beginContainer(0, 0, 10, 10);
        engine.endContainer();
      }
      Flut5Console.flush();
      expect(logs.where((m) => m.contains('visible')), hasLength(1));

      // …and only once: another clip-heavy frame stays silent.
      logs.clear();
      for (var i = 0; i < 200; i++) {
        engine.beginContainer(0, 0, 10, 10);
        engine.endContainer();
      }
      Flut5Console.flush();
      expect(logs, isEmpty);
    });

    test('containerOverflow rules apply to layout-managed containers', () {
      Iterable<ClipRenderItem> clipsFor(Flut5ContainerOverflow mode) {
        final engine = Flut5Engine();
        engine.containerOverflow(mode);
        engine.beginLayout();
        engine.beginContainer(100, 60);
        engine.endContainer();
        engine.endLayout();
        engine.renderQueue.flushPending();
        return engine.renderQueue.items.whereType<ClipRenderItem>();
      }

      // Same snapshot rules as positioned containers: hidden and scroll clip
      // the content to the container's bounds, visible does not.
      expect(clipsFor(Flut5ContainerOverflow.hidden), isNotEmpty);
      expect(clipsFor(Flut5ContainerOverflow.scroll), isNotEmpty);
      expect(clipsFor(Flut5ContainerOverflow.visible), isEmpty);
    });
  });

  test('SketchEnvironment advances frame timing', () {
    final environment = const SketchEnvironment().withSize(
      const Size(320, 180),
    );

    final firstFrame = environment.nextFrame(1000);
    final secondFrame = firstFrame.nextFrame(1016);

    expect(firstFrame.width, 320.0);
    expect(firstFrame.height, 180.0);
    expect(firstFrame.mouseX, 0.0);
    expect(firstFrame.mouseY, 0.0);
    expect(firstFrame.pmouseX, 0.0);
    expect(firstFrame.pmouseY, 0.0);
    expect(firstFrame.frameCount, 1);
    expect(firstFrame.deltaTime, 0.0);
    expect(firstFrame.frameRate(), 0.0);

    expect(secondFrame.frameCount, 2);
    expect(secondFrame.deltaTime, 16.0);
    expect(secondFrame.frameRate(), 62.5);
  });

  test('SketchEnvironment updates mouse positions', () {
    final environment = const SketchEnvironment().withMousePosition(
      mouseX: 12,
      mouseY: 18,
      pmouseX: 4,
      pmouseY: 9,
    );

    expect(environment.mouseX, 12.0);
    expect(environment.mouseY, 18.0);
    expect(environment.pmouseX, 4.0);
    expect(environment.pmouseY, 9.0);
  });

  test('SketchEnvironment updates keyboard state', () {
    final environment = const SketchEnvironment().withKeyboard(
      key: 'a',
      keyCode: 65,
    );

    expect(environment.key, 'a');
    expect(environment.keyCode, 65);
  });

  group('CFF text outlines', () {
    test('flex1 preserves the endpoint on the dominant axis', () {
      final font = CFFData(
        charStrings: [
          _type2CharString([
            0, 0, // rmoveto
            10, 5, 10, 5, 10, 5, 10, 5, 10, 5, 40, // flex1
          ]),
        ],
        globalSubrs: const [],
        localSubrs: const [],
        defaultWidthX: 0,
        nominalWidthX: 0,
      );

      final glyph = Flut5CFFInterpreter.parseGlyph(font, 0);
      final cubics = glyph.commands.whereType<CubicToCommand>().toList();

      expect(cubics, hasLength(2));
      expect(cubics.last.x, 90);
      expect(cubics.last.y, 0);
    });

    test('callgsubr is decoded as an operator, not a long integer', () {
      final font = CFFData(
        charStrings: [
          Uint8List.fromList([
            32, // global subr index 0, biased by -107
            29, // callgsubr
            14, // endchar
          ]),
        ],
        globalSubrs: [
          Uint8List.fromList([
            159, // 20
            159, // 20
            21, // rmoveto
            189, // 50
            139, // 0
            5, // rlineto
            11, // return
          ]),
        ],
        localSubrs: const [],
        defaultWidthX: 0,
        nominalWidthX: 0,
      );

      final glyph = Flut5CFFInterpreter.parseGlyph(font, 0);

      expect(glyph.commands, [
        isA<MoveToCommand>()
            .having((command) => command.x, 'x', 20)
            .having((command) => command.y, 'y', 20),
        isA<LineToCommand>()
            .having((command) => command.x, 'x', 70)
            .having((command) => command.y, 'y', 20),
        isA<CloseCommand>(),
      ]);
    });
  });

  group('Variable fonts', () {
    test('Flut5FontAxis.normalize maps user-space values to [-1, 0, 1]', () {
      const axis = Flut5FontAxis(
        tag: 'wght',
        minValue: 100,
        defaultValue: 400,
        maxValue: 900,
      );
      expect(axis.normalize(400), 0.0);
      expect(axis.normalize(100), -1.0);
      expect(axis.normalize(900), 1.0);
      // 700 is 60% of the way from 400 (default) to 900 (max).
      expect(axis.normalize(700), closeTo(0.6, 1e-9));
      // 250 is 50% of the way from 400 (default) toward 100 (min).
      expect(axis.normalize(250), closeTo(-0.5, 1e-9));
      // Out-of-range values clamp before normalizing.
      expect(axis.normalize(1500), 1.0);
      expect(axis.normalize(-50), -1.0);
    });

    test('Flut5FontAxis.clampValue clips to declared range', () {
      const axis = Flut5FontAxis(
        tag: 'wdth',
        minValue: 50,
        defaultValue: 100,
        maxValue: 200,
      );
      expect(axis.clampValue(75), 75);
      expect(axis.clampValue(25), 50);
      expect(axis.clampValue(300), 200);
    });

    test(
      'textWeight() is a getter when no arg, a setter when given a number',
      () {
        final engine = Flut5Engine();
        // Default weight is 400 (Regular).
        expect(engine.textWeight(), 400.0);
        // Setting returns the new value; reading back agrees.
        expect(engine.textWeight(700), 700.0);
        expect(engine.textWeight(), 700.0);
        // Fractional values are preserved (rasterized side rounds to the
        // nearest FontWeight enum internally; the engine stores the exact
        // value so VF axes get sub-100 precision).
        expect(engine.textWeight(450.5), 450.5);
      },
    );

    test(
      'variable-font axis API is a no-op when no outline font is loaded',
      () {
        final engine = Flut5Engine();
        expect(engine.fontAxes, isEmpty);
        // None of these should throw.
        engine.fontAxis('wght', 700);
        engine.fontInstance('Bold');
        engine.clearFontAxes();
        expect(engine.fontAxes, isEmpty);
      },
    );

    test('gvar packed deltas decode zero and word runs correctly', () {
      // One glyph-variation record with a single embedded-peak tuple:
      // x deltas are an all-zero run; y deltas are two signed 16-bit values.
      final data = ByteData(20);
      data.setUint16(0, 0x0001); // tupleVariationCount
      data.setUint16(2, 10); // serialized data starts after the tuple header
      data.setUint16(4, 10); // variationDataSize
      data.setUint16(6, 0xA000); // embedded peak tuple with private points
      data.setInt16(8, 0x4000); // peak coord: +1.0
      data.setUint8(10, 2); // two private point numbers
      data.setUint8(11, 0x01); // point numbers: byte run, 2 values
      data.setUint8(12, 0); // point 0
      data.setUint8(13, 1); // point 1
      data.setUint8(14, 0x81); // x: zero run, 2 values
      data.setUint8(15, 0x41); // y: word run, 2 values
      data.setInt16(16, 10);
      data.setInt16(18, -20);

      final deltas = resolveSimpleGlyphGvarDeltas(
        gvar: Flut5GvarData(
          bytes: data,
          axisCount: 1,
          sharedTupleCount: 0,
          sharedTuplesOffset: 0,
          glyphVariationDataArrayOffset: 0,
          glyphVariationDataOffsets: const [0, 20],
        ),
        glyphIndex: 0,
        normalizedCoords: const [1.0],
        pointCount: 2,
        xCoords: const [0, 100],
        yCoords: const [0, 100],
        endPts: const [1],
      );

      expect(deltas, isNotNull);
      expect(deltas![0].dx, 0);
      expect(deltas[1].dx, 0);
      expect(deltas[0].dy, 10);
      expect(deltas[1].dy, -20);
    });

    test('gvar all-points tuples consume phantom point deltas', () {
      // `gvar` all-points tuples encode the real outline points plus four
      // phantom points. The phantom values are not applied to outlines here,
      // but they must be consumed before reading the y-delta stream.
      final data = ByteData(24);
      data.setUint16(0, 0x0001); // tupleVariationCount
      data.setUint16(2, 10); // serialized data starts after the tuple header
      data.setUint16(4, 14); // variationDataSize
      data.setUint16(6, 0x8000); // embedded peak tuple
      data.setInt16(8, 0x4000); // peak coord: +1.0
      data.setUint8(10, 0x05); // x: byte run, 6 values
      for (var i = 0; i < 6; i++) {
        data.setInt8(11 + i, [1, 2, 30, 40, 50, 60][i]);
      }
      data.setUint8(17, 0x05); // y: byte run, 6 values
      for (var i = 0; i < 6; i++) {
        data.setInt8(18 + i, [3, 4, 70, 80, 90, 100][i]);
      }

      final deltas = resolveSimpleGlyphGvarDeltas(
        gvar: Flut5GvarData(
          bytes: data,
          axisCount: 1,
          sharedTupleCount: 0,
          sharedTuplesOffset: 0,
          glyphVariationDataArrayOffset: 0,
          glyphVariationDataOffsets: const [0, 24],
        ),
        glyphIndex: 0,
        normalizedCoords: const [1.0],
        pointCount: 2,
        xCoords: const [0, 100],
        yCoords: const [0, 100],
        endPts: const [1],
      );

      expect(deltas, isNotNull);
      expect(deltas![0].dx, 1);
      expect(deltas[1].dx, 2);
      expect(deltas[0].dy, 3);
      expect(deltas[1].dy, 4);
    });
  });

  group('Registered font shape data', () {
    test('textFont family selects preloaded font for outline APIs', () {
      final glyph = Flut5Glyph(
        commands: const [
          MoveToCommand(0, 0),
          LineToCommand(100, 0),
          LineToCommand(100, 100),
          LineToCommand(0, 100),
          CloseCommand(),
        ],
        xMin: 0,
        yMin: 0,
        xMax: 100,
        yMax: 100,
      );
      final font = Flut5Font.internal(
        unitsPerEm: 100,
        numGlyphs: 2,
        numberOfHMetrics: 2,
        charToGlyph: const {120: 1},
        glyphs: [Flut5Glyph.empty, glyph],
        advanceWidths: const [0, 200],
        lsbs: const [0, 0],
      );
      final engine = Flut5Engine();
      engine.environment = engine.environment.withFonts({
        'SketchFont': Flut5FontData(
          name: 'SketchFont',
          asset: 'assets/fonts/SketchFont.ttf',
          font: font,
        ),
      });

      engine
        ..textFont('SketchFont')
        ..textSize(50);

      final commands = engine.textToPaths('x', 10, 20);

      expect(commands, hasLength(5));
      expect(commands[0], isA<MoveToCommand>());
      final move = commands[0] as MoveToCommand;
      expect(move.x, 10);
      expect(move.y, 20);
      expect(
        commands.whereType<LineToCommand>().map((cmd) => (cmd.x, cmd.y)),
        contains((60.0, -30.0)),
      );
    });

    test(
      'loadFont resolves a pubspec family name from the preloaded map',
      () async {
        final glyph = Flut5Glyph(
          commands: const [
            MoveToCommand(0, 0),
            LineToCommand(100, 0),
            LineToCommand(100, 100),
            LineToCommand(0, 100),
            CloseCommand(),
          ],
          xMin: 0,
          yMin: 0,
          xMax: 100,
          yMax: 100,
        );
        final font = Flut5Font.internal(
          unitsPerEm: 100,
          numGlyphs: 2,
          numberOfHMetrics: 2,
          charToGlyph: const {120: 1},
          glyphs: [Flut5Glyph.empty, glyph],
          advanceWidths: const [0, 200],
          lsbs: const [0, 0],
        );
        final engine = Flut5Engine();
        engine.environment = engine.environment.withFonts({
          'SketchFont': Flut5FontData(
            name: 'SketchFont',
            asset: 'assets/fonts/SketchFont.ttf',
            font: font,
          ),
        });

        final loaded = await engine.loadFont('SketchFont');

        expect(identical(loaded, font), isTrue);
        engine.textSize(50);
        final commands = engine.textToPaths('x', 10, 20);
        expect(commands, hasLength(5));
        expect(commands[0], isA<MoveToCommand>());
      },
    );

    test('outline APIs apply letterSpacing between glyphs', () {
      // 100 upem square glyph, 200 upem advance. At textSize 50 the scale is
      // 0.5 → 50px wide glyph, 100px advance.
      final glyph = Flut5Glyph(
        commands: const [
          MoveToCommand(0, 0),
          LineToCommand(100, 0),
          LineToCommand(100, 100),
          LineToCommand(0, 100),
          CloseCommand(),
        ],
        xMin: 0,
        yMin: 0,
        xMax: 100,
        yMax: 100,
      );
      Flut5Engine buildEngine(double spacing) {
        final font = Flut5Font.internal(
          unitsPerEm: 100,
          numGlyphs: 2,
          numberOfHMetrics: 2,
          charToGlyph: const {120: 1},
          glyphs: [Flut5Glyph.empty, glyph],
          advanceWidths: const [0, 200],
          lsbs: const [0, 0],
        );
        final engine = Flut5Engine();
        engine.environment = engine.environment.withFonts({
          'SketchFont': Flut5FontData(
            name: 'SketchFont',
            asset: 'assets/fonts/SketchFont.ttf',
            font: font,
          ),
        });
        return engine
          ..textFont('SketchFont')
          ..textSize(50)
          ..letterSpacing(spacing);
      }

      double secondGlyphOrigin(List<PathCommand> cmds) =>
          (cmds.whereType<MoveToCommand>().elementAt(1)).x;

      // No spacing: second glyph sits one advance (100px) after the first.
      expect(
        secondGlyphOrigin(buildEngine(0).textToPaths('xx', 10, 20)),
        110.0,
      );
      // 20px spacing is inserted once, between the two glyphs.
      expect(
        secondGlyphOrigin(buildEngine(20).textToPaths('xx', 10, 20)),
        130.0,
      );

      // Nothing is added after the last glyph — a single glyph is unaffected.
      final single = buildEngine(20).textToPaths('x', 10, 20);
      expect((single.first as MoveToCommand).x, 10.0);

      // Contours and points ride the same cursor.
      final contours = buildEngine(20).textToContours('xx', 10, 20);
      expect(contours, hasLength(2));
      expect(contours[0].map((p) => p.x).reduce(math.min), closeTo(10, 0.001));
      expect(contours[1].map((p) => p.x).reduce(math.min), closeTo(130, 0.001));

      final points = buildEngine(20).textToPoints('xx', 10, 20);
      expect(points.map((p) => p.x).reduce(math.max), closeTo(180, 0.001));

      // Outline width now agrees with textWidth's N-1 spacing insertions.
      final spaced = buildEngine(20).textToPoints('xx', 0, 0);
      final xs = spaced.map((p) => p.x);
      expect(xs.reduce(math.max) - xs.reduce(math.min), closeTo(170, 0.001));
    });
  });

  group('textToGrid', () {
    // A 100 upem square glyph with a 200 upem advance. Rendered at fontSize
    // 100 the scale is 1, so the glyph is a 100x100 px square whose edges
    // land exactly on 10px cell boundaries.
    Flut5Engine buildEngine(List<PathCommand> commands) {
      final glyph = Flut5Glyph(
        commands: commands,
        xMin: 0,
        yMin: 0,
        xMax: 100,
        yMax: 100,
      );
      final font = Flut5Font.internal(
        unitsPerEm: 100,
        numGlyphs: 2,
        numberOfHMetrics: 2,
        charToGlyph: const {120: 1},
        glyphs: [Flut5Glyph.empty, glyph],
        advanceWidths: const [0, 200],
        lsbs: const [0, 0],
      );
      final engine = Flut5Engine();
      engine.environment = engine.environment.withFonts({
        'SketchFont': Flut5FontData(
          name: 'SketchFont',
          asset: 'assets/fonts/SketchFont.ttf',
          font: font,
        ),
      });
      return engine
        ..textFont('SketchFont')
        ..textSize(100);
    }

    const solidSquare = <PathCommand>[
      MoveToCommand(0, 0),
      LineToCommand(100, 0),
      LineToCommand(100, 100),
      LineToCommand(0, 100),
      CloseCommand(),
    ];

    test('spans the outline bbox and classifies edge vs interior', () {
      final grid = buildEngine(solidSquare)
          .textToGrid('x', 0, 0, args: {Flut5TextArg.cellSize: 10});

      // The glyph occupies x 0..100 and, after the baseline Y-flip, y -100..0.
      expect(grid.cols, 10);
      expect(grid.rows, 10);
      expect(grid.x, closeTo(0, 0.001));
      expect(grid.y, closeTo(-100, 0.001));
      expect(grid.cellSize, 10);
      expect(grid.width, closeTo(100, 0.001));

      for (int r = 0; r < grid.rows; r++) {
        for (int c = 0; c < grid.cols; c++) {
          final onBorder = r == 0 || c == 0 || r == 9 || c == 9;
          expect(
            grid[r][c],
            onBorder ? Flut5CellState.edge : Flut5CellState.interior,
            reason: 'cell ($c, $r)',
          );
        }
      }

      // Everything inside the outline is filled; nothing here is empty.
      expect(
        grid.states.expand((row) => row).every((state) => state.isFilled),
        isTrue,
      );
    });

    test('leaves counters empty via nonzero winding', () {
      // Outer contour counterclockwise, inner clockwise — an "O"-style hole
      // spanning 30..70 in both axes.
      final grid = buildEngine(const <PathCommand>[
        MoveToCommand(0, 0),
        LineToCommand(100, 0),
        LineToCommand(100, 100),
        LineToCommand(0, 100),
        CloseCommand(),
        MoveToCommand(30, 30),
        LineToCommand(30, 70),
        LineToCommand(70, 70),
        LineToCommand(70, 30),
        CloseCommand(),
      ]).textToGrid('x', 0, 0, args: {Flut5TextArg.cellSize: 10});

      // The hole's walls sit on cols/rows 3 and 7, so 4..6 is clean interior.
      for (int r = 4; r <= 6; r++) {
        for (int c = 4; c <= 6; c++) {
          expect(
            grid[r][c],
            Flut5CellState.empty,
            reason: 'hole cell ($c, $r)',
          );
        }
      }
      // The ring between outer wall and counter is still solid.
      expect(grid[5][1], Flut5CellState.interior);
      expect(grid[1][5], Flut5CellState.interior);
      // Both walls register as edges.
      expect(grid[5][3], Flut5CellState.edge);
      expect(grid[5][7], Flut5CellState.edge);
    });

    test('edge is the shape border, not every cell an outline grazes', () {
      // A slanted-sided parallelogram. Its edges climb one column every two
      // rows, so the segment walk steps diagonally and marks both cells of
      // each staircase step. The inner cell of that pair sits fully inside
      // the glyph — it used to come back edge, painting a second red line
      // down the middle of the stroke in Demo 9.
      final grid = buildEngine(const <PathCommand>[
        MoveToCommand(0, 0),
        LineToCommand(60, 0),
        LineToCommand(100, 100),
        LineToCommand(40, 100),
        CloseCommand(),
      ]).textToGrid('x', 0, 0, args: {Flut5TextArg.cellSize: 10});

      // Row 2 runs cols 2..9; only its two ends touch empty space, so the
      // cells just inside them are body, not outline.
      expect(grid[2][2], Flut5CellState.edge);
      expect(grid[2][3], Flut5CellState.interior, reason: 'walled in');
      expect(grid[2][9], Flut5CellState.edge);
      expect(grid[2][8], Flut5CellState.interior, reason: 'walled in');
      // The same staircase step, lower down the slant: row 7 runs cols 0..7.
      expect(grid[7][0], Flut5CellState.edge);
      expect(grid[7][1], Flut5CellState.interior, reason: 'walled in');
      expect(grid[7][7], Flut5CellState.edge);
      expect(grid[7][6], Flut5CellState.interior, reason: 'walled in');
      // Each row of the slant is a solid run with exactly two outline cells.
      for (final r in [2, 4, 7]) {
        final outline = [
          for (int c = 0; c < grid.cols; c++)
            if (grid[r][c] == Flut5CellState.edge) c,
        ];
        expect(outline, hasLength(2), reason: 'row $r');
      }
    });

    test('edge exactly means filled with an empty or off-grid neighbor', () {
      // The invariant behind the classification, checked over a glyph with a
      // counter, slanted walls, and cells against all four sides of the box.
      final grid = buildEngine(const <PathCommand>[
        MoveToCommand(0, 0),
        LineToCommand(100, 0),
        LineToCommand(70, 100),
        LineToCommand(0, 100),
        CloseCommand(),
        MoveToCommand(30, 30),
        LineToCommand(30, 70),
        LineToCommand(60, 70),
        LineToCommand(60, 30),
        CloseCommand(),
      ]).textToGrid('x', 0, 0, args: {Flut5TextArg.cellSize: 5});

      for (int r = 0; r < grid.rows; r++) {
        for (int c = 0; c < grid.cols; c++) {
          final state = grid[r][c];
          if (!state.isFilled) continue;
          // stateAt reports off-grid as empty, so the box rim counts as
          // exposed without a separate bounds check.
          final exposed =
              !grid.stateAt(c - 1, r).isFilled ||
              !grid.stateAt(c + 1, r).isFilled ||
              !grid.stateAt(c, r - 1).isFilled ||
              !grid.stateAt(c, r + 1).isFilled;
          expect(
            state,
            exposed ? Flut5CellState.edge : Flut5CellState.interior,
            reason: 'cell ($c, $r)',
          );
        }
      }
      // Guard against the invariant passing vacuously on a one-state grid.
      final states = grid.states.expand((row) => row).toSet();
      expect(states, containsAll(Flut5CellState.values));
    });

    test('defaults cellSize to 4px regardless of font size', () {
      final grid = buildEngine(solidSquare).textToGrid('x', 0, 0);

      // 4px cells over a 100px square → 25 cells across.
      expect(grid.cellSize, closeTo(4, 0.001));
      expect(grid.cols, 25);
      expect(grid.rows, 25);
    });

    test('honors letterSpacing when sizing the grid', () {
      final tight = buildEngine(solidSquare)
          .textToGrid('xx', 0, 0, args: {Flut5TextArg.cellSize: 10});
      final spaced = (buildEngine(solidSquare)..letterSpacing(20)).textToGrid(
        'xx',
        0,
        0,
        args: {Flut5TextArg.cellSize: 10},
      );
      // The args map overrides engine state for this call only — previously
      // letterSpacing was ambient-only and had no per-call form.
      final viaArgs = buildEngine(solidSquare).textToGrid(
        'xx',
        0,
        0,
        args: {Flut5TextArg.cellSize: 10, Flut5TextArg.letterSpacing: 20},
      );

      // Advance 200 + glyph 100 = 300px wide; spacing adds one 20px gap.
      expect(tight.cols, 30);
      expect(spaced.cols, 32);
      expect(viaArgs.cols, 32);
      expect(spaced.rows, tight.rows);
    });

    test('returns an empty grid for text with no outline', () {
      final grid = buildEngine(solidSquare).textToGrid('   ', 0, 0);

      expect(grid.isEmpty, isTrue);
      expect(grid.rows, 0);
      expect(grid.cols, 0);
      // Out-of-range reads are safe rather than throwing.
      expect(grid.stateAt(5, 5), Flut5CellState.empty);
      expect(grid.cellAt(5, 5).state, Flut5CellState.empty);
      expect(grid.allCells, isEmpty);
      expect(grid.filledCells, isEmpty);
    });

    test('cellAt carries indices, geometry, and state together', () {
      final grid = buildEngine(solidSquare)
          .textToGrid('x', 0, 0, args: {Flut5TextArg.cellSize: 10});
      final cell = grid.cellAt(3, 4);

      expect(cell.col, 3);
      expect(cell.row, 4);
      expect(cell.state, Flut5CellState.interior);
      expect(cell.isFilled, isTrue);
      // Geometry agrees with the index-based accessors.
      expect(cell.anchorX, grid.xAt(3));
      expect(cell.anchorY, grid.yAt(4));
      expect(cell.size, grid.cellSize);
      // anchor is the top-left corner, position is the center — half a cell
      // apart, and each pairs with a different family of primitives.
      expect(cell.anchor.x, closeTo(grid.xAt(3), 0.001));
      expect(cell.anchor.y, closeTo(grid.yAt(4), 0.001));
      expect(cell.position.x, closeTo(grid.cellCenter(3, 4).x, 0.001));
      expect(cell.position.y, closeTo(grid.cellCenter(3, 4).y, 0.001));
      expect(cell.position.x - cell.anchor.x, closeTo(cell.size / 2, 0.001));
      expect(cell.position.y - cell.anchor.y, closeTo(cell.size / 2, 0.001));
      expect(cell.bounds, Rect.fromLTWH(grid.xAt(3), grid.yAt(4), 10, 10));

      // Out-of-range still resolves geometry rather than throwing.
      final outside = grid.cellAt(-1, 99);
      expect(outside.state, Flut5CellState.empty);
      expect(outside.isFilled, isFalse);
      expect(outside.anchorX, grid.xAt(-1));
      expect(outside.anchorY, grid.yAt(99));
    });

    test('allCells walks every cell row-major and round-trips indices', () {
      final grid = buildEngine(solidSquare)
          .textToGrid('x', 0, 0, args: {Flut5TextArg.cellSize: 10});
      final cells = grid.allCells.toList();

      expect(cells, hasLength(grid.rows * grid.cols));
      // Row-major: top-left first, then left to right.
      expect(cells.first.col, 0);
      expect(cells.first.row, 0);
      expect(cells[1].col, 1);
      expect(cells[1].row, 0);
      expect(cells.last.col, grid.cols - 1);
      expect(cells.last.row, grid.rows - 1);

      // Every cell's indices point back at its own state.
      for (final cell in cells) {
        expect(cell.state, grid[cell.row][cell.col], reason: '$cell');
      }
    });

    test('filledCells skips empty cells and stays lazy', () {
      // The counter glyph from above — 100x100 box with a 40x40 hole.
      final grid = buildEngine(const <PathCommand>[
        MoveToCommand(0, 0),
        LineToCommand(100, 0),
        LineToCommand(100, 100),
        LineToCommand(0, 100),
        CloseCommand(),
        MoveToCommand(30, 30),
        LineToCommand(30, 70),
        LineToCommand(70, 70),
        LineToCommand(70, 30),
        CloseCommand(),
      ]).textToGrid('x', 0, 0, args: {Flut5TextArg.cellSize: 10});

      final filled = grid.filledCells.toList();
      final all = grid.allCells.toList();

      expect(filled.every((c) => c.isFilled), isTrue);
      expect(filled, hasLength(all.where((c) => c.isFilled).length));
      expect(filled.length, lessThan(all.length), reason: 'the hole is empty');
      // The counter's cells never show up.
      expect(filled.any((c) => c.col == 5 && c.row == 5), isFalse);

      // Lazy: taking a few does not walk or allocate the whole grid.
      expect(grid.filledCells.take(3).toList(), hasLength(3));

      // Detached cells stay usable — this is the case a bare 2D array loses.
      final outline = filled
          .where((c) => c.state == Flut5CellState.edge)
          .toList();
      expect(outline, isNotEmpty);
      expect(outline.every((c) => c.state == Flut5CellState.edge), isTrue);
      expect(
        outline.every(
          (c) => c.anchorX == grid.xAt(c.col) && c.anchorY == grid.yAt(c.row),
        ),
        isTrue,
      );
    });
  });

  group('text outline args map', () {
    // Same 100 upem square glyph, 200 upem advance, rendered at fontSize 100.
    Flut5Engine buildEngine() {
      final glyph = Flut5Glyph(
        commands: const <PathCommand>[
          MoveToCommand(0, 0),
          LineToCommand(100, 0),
          LineToCommand(100, 100),
          LineToCommand(0, 100),
          CloseCommand(),
        ],
        xMin: 0,
        yMin: 0,
        xMax: 100,
        yMax: 100,
      );
      final font = Flut5Font.internal(
        unitsPerEm: 100,
        numGlyphs: 2,
        numberOfHMetrics: 2,
        charToGlyph: const {120: 1},
        glyphs: [Flut5Glyph.empty, glyph],
        advanceWidths: const [0, 200],
        lsbs: const [0, 0],
      );
      final engine = Flut5Engine();
      engine.environment = engine.environment.withFonts({
        'SketchFont': Flut5FontData(
          name: 'SketchFont',
          asset: 'assets/fonts/SketchFont.ttf',
          font: font,
        ),
      });
      return engine
        ..textFont('SketchFont')
        ..textSize(100);
    }

    test('coerces int values, since a map has no double context', () {
      // `10` and `100` are int literals here — inside Map<String, dynamic>
      // they stay ints, so the read side must coerce rather than throw.
      final grid = buildEngine().textToGrid(
        'x',
        0,
        0,
        args: {Flut5TextArg.cellSize: 10, Flut5TextArg.fontSize: 100},
      );

      expect(grid.cellSize, 10.0);
      expect(grid.cols, 10);
    });

    test('ignores unknown and inapplicable keys instead of throwing', () {
      final grid = buildEngine().textToGrid(
        'x',
        0,
        0,
        args: {
          Flut5TextArg.cellSize: 10,
          'cellSise': 999, // typo
          Flut5TextArg.sampleFactor: 4, // valid key, but not for textToGrid
        },
      );

      expect(grid.cellSize, 10.0);
      expect(grid.cols, 10);
    });

    test('ignores wrong-typed values and falls back to the default', () {
      final grid = buildEngine().textToGrid(
        'x',
        0,
        0,
        args: {Flut5TextArg.cellSize: 'ten', Flut5TextArg.font: 'not a font'},
      );

      // Falls back to the 4px default, and to the engine's loaded font.
      expect(grid.cellSize, closeTo(4, 0.001));
      expect(grid.isEmpty, isFalse);
    });

    test('a null args map behaves exactly like no overrides', () {
      final a = buildEngine().textToGrid('x', 0, 0);
      final b = buildEngine().textToGrid('x', 0, 0, args: null);

      expect(b.cols, a.cols);
      expect(b.rows, a.rows);
      expect(b.cellSize, a.cellSize);
    });

    test('overrides apply per call without mutating engine state', () {
      final engine = buildEngine();

      // fontSize 50 → scale 0.5 → a 50px glyph over 10px cells.
      final small = engine.textToGrid(
        'x',
        0,
        0,
        args: {Flut5TextArg.fontSize: 50, Flut5TextArg.cellSize: 10},
      );
      expect(small.cols, 5);

      // The engine's own textSize is untouched.
      final normal = engine.textToGrid(
        'x',
        0,
        0,
        args: {Flut5TextArg.cellSize: 10},
      );
      expect(normal.cols, 10);
    });

    test('sampleFactor and simplifyThreshold route through the map', () {
      final engine = buildEngine();
      final sparse = engine.textToPoints(
        'x',
        0,
        0,
        args: {Flut5TextArg.sampleFactor: 0.1},
      );
      final dense = engine.textToPoints(
        'x',
        0,
        0,
        args: {Flut5TextArg.sampleFactor: 2.0},
      );

      expect(dense.length, greaterThan(sparse.length));
    });
  });

  group('Raster text layout', () {
    test('dynamic text applies letter spacing across spaces', () async {
      Future<_AlphaBounds> renderBounds(double spacing) {
        final engine = Flut5Engine()
          ..textSize(48)
          ..letterSpacing(spacing)
          ..fill(Colors.white)
          ..noStroke()
          ..text('A A', 10, 8);
        return _renderAlphaBounds(engine, 240, 90);
      }

      final normal = await renderBounds(0);
      final spaced = await renderBounds(30);

      expect(spaced.width, greaterThan(normal.width + 40));
    });

    test('static text cache applies letter spacing', () async {
      Future<_AlphaBounds> renderBounds(double spacing) {
        final engine = Flut5Engine()
          ..textCacheMode(TextCacheMode.static)
          ..textSize(48)
          ..letterSpacing(spacing)
          ..fill(Colors.white)
          ..noStroke()
          ..text('A A', 10, 8);
        return _renderAlphaBounds(engine, 240, 90);
      }

      final normal = await renderBounds(0);
      final spaced = await renderBounds(30);

      expect(spaced.width, greaterThan(normal.width + 40));
    });

    test('dynamic gradient text preserves skewed glyph overhang', () async {
      await _loadTestFont(
        'GambarinoRegression',
        'agent_assets/Gambarino-Regular.otf',
      );

      Future<_AlphaBounds> renderBounds(Object fill) {
        final engine = Flut5Engine()
          ..textFont('GambarinoRegression')
          ..textSize(96)
          ..fill(fill)
          ..noStroke()
          ..text('ttuvv', 40, 8);
        return _renderAlphaBounds(engine, 500, 140);
      }

      final solid = await renderBounds(Colors.white);
      final gradient = await renderBounds(
        const LinearGradient(colors: [Colors.white, Colors.white]),
      );

      expect(gradient.minX, lessThanOrEqualTo(solid.minX));
      expect(gradient.maxX, greaterThanOrEqualTo(solid.maxX));
      expect(gradient.width, greaterThanOrEqualTo(solid.width));
    });

    test('dynamic text cache pads skewed glyph textures', () async {
      await _loadTestFont(
        'GambarinoCachePadding',
        'agent_assets/Gambarino-Regular.otf',
      );

      final cached = Flut5TextCache.instance.getOrCreate(
        text: 't',
        fontFamily: 'GambarinoCachePadding',
        fontSize: 96,
        fontWeight: FontWeight.normal,
        fontStyle: FontStyle.normal,
        textLeading: null,
        align: TextAlign.left,
        paintingStyle: 0,
        strokeWidth: 0,
      );
      final bounds = await _imageAlphaBounds(cached.image);

      expect(cached.leftPad, greaterThan(0));
      expect(cached.drawWidth, greaterThan(cached.width));
      expect(bounds.minX, greaterThan(0));
      expect(bounds.maxX, lessThan(cached.image.width - 1));
    });
  });

  group('Glyph sampling', () {
    test('equivalent curve contours sample independently of command count', () {
      final quadraticContours = Flut5GlyphSampler.sampleContours(const [
        MoveToCommand(10, 0),
        QuadToCommand(10, 10, 0, 10),
        QuadToCommand(-10, 10, -10, 0),
        QuadToCommand(-10, -10, 0, -10),
        QuadToCommand(10, -10, 10, 0),
        CloseCommand(),
      ], sampleFactor: 0.1);

      const k = 5.522847498307934;
      final cubicContours = Flut5GlyphSampler.sampleContours(const [
        MoveToCommand(10, 0),
        CubicToCommand(10, k, k, 10, 0, 10),
        CubicToCommand(-k, 10, -10, k, -10, 0),
        CubicToCommand(-10, -k, -k, -10, 0, -10),
        CubicToCommand(k, -10, 10, -k, 10, 0),
        CloseCommand(),
      ], sampleFactor: 0.1);

      expect(quadraticContours, hasLength(1));
      expect(cubicContours, hasLength(1));
      expect(quadraticContours.single, hasLength(cubicContours.single.length));
      expect(quadraticContours.single, hasLength(8));
      expect(_minGap(quadraticContours.single), greaterThan(0));
      expect(_minGap(cubicContours.single), greaterThan(0));
    });
  });

  group('Trail background detection', () {
    test('empty queue accounts for pending batches', () {
      final queue = Flut5RenderQueue();
      expect(queue.isEmpty, isTrue);

      queue.appendPoint(1, 2, Paint());

      expect(queue.isEmpty, isFalse);
    });

    test('opaque color backgrounds clear trail snapshots', () {
      final queue = Flut5RenderQueue();

      queue.enqueue(BackgroundRenderItem(Colors.white));

      expect(queue.lastBackgroundIsOpaqueFullCanvas, isTrue);
      expect(queue.hasOpaqueFullCanvasBackground, isTrue);
    });

    test('translucent color backgrounds keep trails active', () {
      final queue = Flut5RenderQueue();

      queue.enqueue(BackgroundRenderItem(const Color(0x80FFFFFF)));

      expect(queue.lastBackgroundIsOpaqueFullCanvas, isFalse);
      expect(queue.hasOpaqueFullCanvasBackground, isFalse);
    });

    test('full-canvas gradient backgrounds use explicit opacity', () {
      final queue = Flut5RenderQueue();

      queue.enqueue(
        BackgroundRenderItem.shader(Paint(), null, isOpaque: false),
      );

      expect(queue.lastBackgroundIsOpaqueFullCanvas, isFalse);
      expect(queue.hasOpaqueFullCanvasBackground, isFalse);

      queue.clear();
      queue.enqueue(BackgroundRenderItem.shader(Paint(), null, isOpaque: true));

      expect(queue.lastBackgroundIsOpaqueFullCanvas, isTrue);
      expect(queue.hasOpaqueFullCanvasBackground, isTrue);
    });

    test('partial opaque gradient backgrounds do not clear trails', () {
      final queue = Flut5RenderQueue();

      queue.enqueue(
        BackgroundRenderItem.shader(
          Paint(),
          const Rect.fromLTWH(0, 0, 10, 10),
          isOpaque: true,
        ),
      );

      expect(queue.lastBackgroundIsOpaqueFullCanvas, isFalse);
      expect(queue.hasOpaqueFullCanvasBackground, isFalse);
    });
  });

  group('Blend modes', () {
    test('p5-style constants map to Flutter blend modes', () {
      expect(BLEND, BlendMode.srcOver);
      expect(ADD, BlendMode.plus);
      expect(DARKEST, BlendMode.darken);
      expect(LIGHTEST, BlendMode.lighten);
      expect(EXCLUSION, BlendMode.exclusion);
      expect(MULTIPLY, BlendMode.multiply);
      expect(SCREEN, BlendMode.screen);
      expect(REPLACE, BlendMode.src);
      expect(REMOVE, BlendMode.dstOut);
      expect(DIFFERENCE, BlendMode.difference);
      expect(OVERLAY, BlendMode.overlay);
      expect(HARD_LIGHT, BlendMode.hardLight);
      expect(SOFT_LIGHT, BlendMode.softLight);
      expect(DODGE, BlendMode.colorDodge);
      expect(BURN, BlendMode.colorBurn);
      expect(SUBTRACT, BlendMode.difference);
    });

    test('blendMode refreshes fill, stroke, and point paint snapshots', () {
      final engine = Flut5Engine();

      engine.blendMode(ADD);

      expect(engine.currentBlendMode, ADD);
      expect(engine.getFillPaint().blendMode, ADD);
      expect(engine.snapshotFillPaint()!.blendMode, ADD);
      expect(engine.getStrokePaint().blendMode, ADD);
      expect(engine.snapshotStrokePaint()!.blendMode, ADD);
      expect(engine.snapshotPointPaint()!.blendMode, ADD);

      engine.blendMode(MULTIPLY);

      expect(engine.currentBlendMode, MULTIPLY);
      expect(engine.snapshotFillPaint()!.blendMode, MULTIPLY);
      expect(engine.snapshotStrokePaint()!.blendMode, MULTIPLY);
      expect(engine.snapshotPointPaint()!.blendMode, MULTIPLY);
    });

    test('blendMode cannot change inside beginBatch/endBatch', () {
      final engine = Flut5Engine();

      engine.beginBatch();

      expect(() => engine.blendMode(ADD), throwsA(isA<FlutterError>()));

      engine.endBatch();
    });

    test('shapes with opacity use the active blend mode', () async {
      final engine = Flut5Engine()
        ..environment = const SketchEnvironment().withSize(const Size(4, 4));

      engine.background(const Color(0xFF0000FF));
      engine.noStroke();
      engine.fill(const Color(0x80FF0000));
      engine.blendMode(MULTIPLY);
      engine.rect(0, 0, 4, 4);

      final pixel = await _renderPixel(engine, 4, 4, x: 2, y: 2);

      expect(pixel.red, lessThan(64));
      expect(pixel.green, lessThan(16));
      expect(pixel.blue, inInclusiveRange(120, 140));
      expect(pixel.alpha, 255);
    });
  });

  // ── NoiseMode ────────────────────────────────────────────────────────

  test('default noiseMode is simplex', () {
    final engine = Flut5Engine();
    expect(engine.noiseMode, NoiseMode.simplex);
  });

  // ── Simplex noise (default) ──────────────────────────────────────────

  group('dist / distSq', () {
    test('measures a 3-4-5 triangle', () {
      final engine = Flut5Engine();
      expect(engine.dist(0, 0, 3, 4), closeTo(5, 1e-12));
      expect(engine.distSq(0, 0, 3, 4), closeTo(25, 1e-12));
    });

    test('is symmetric and sign-independent', () {
      final engine = Flut5Engine();
      expect(
        engine.dist(10, 20, -5, 8),
        closeTo(engine.dist(-5, 8, 10, 20), 1e-12),
      );
      expect(engine.dist(-3, -4, 0, 0), closeTo(5, 1e-12));
    });

    test('coincident points measure zero', () {
      final engine = Flut5Engine();
      expect(engine.dist(7, -2, 7, -2), 0);
      expect(engine.distSq(7, -2, 7, -2), 0);
    });

    test('distSq orders the same as dist, without the root', () {
      final engine = Flut5Engine();
      final near = engine.dist(0, 0, 2, 2);
      final far = engine.dist(0, 0, 9, 1);
      expect(near, lessThan(far));
      expect(engine.distSq(0, 0, 2, 2), lessThan(engine.distSq(0, 0, 9, 1)));
      expect(engine.distSq(0, 0, 9, 1), closeTo(far * far, 1e-9));
    });

    test('agrees with Flut5Vector.dist on the z = 0 plane', () {
      final engine = Flut5Engine();
      final a = Flut5Vector(12, -3);
      final b = Flut5Vector(-4, 9);
      expect(engine.dist(a.x, a.y, b.x, b.y), closeTo(a.dist(b), 1e-12));
      expect(engine.dist(a, b), closeTo(a.dist(b), 1e-12));
    });

    test('the two-vector form measures in 3-D', () {
      final engine = Flut5Engine();
      final a = Flut5Vector(0, 0, 0);
      final b = Flut5Vector(3, 4, 12);
      // 3-4-12 is a Pythagorean quadruple: sqrt(9 + 16 + 144) == 13.
      expect(engine.dist(a, b), closeTo(13, 1e-12));
      expect(engine.distSq(a, b), closeTo(169, 1e-12));
      // The number form only ever sees x and y, so it drops the z leg.
      expect(engine.dist(a.x, a.y, b.x, b.y), closeTo(5, 1e-12));
    });

    test('accepts a bare Vector3, not just Flut5Vector', () {
      final engine = Flut5Engine();
      expect(
        engine.dist(Vector3(0, 0, 0), Vector3(0, 3, 4)),
        closeTo(5, 1e-12),
      );
    });

    test('int arguments are accepted in the number form', () {
      final engine = Flut5Engine();
      expect(engine.dist(0, 0, 3, 4), closeTo(5, 1e-12));
      expect(engine.distSq(0, 0, 3, 4), closeTo(25, 1e-12));
    });

    test('a shape that is neither form throws with both spellings named', () {
      final engine = Flut5Engine();
      final v = Flut5Vector(1, 2);

      // Two numbers, no second point.
      expect(
        () => engine.dist(1, 2),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('dist(x1, y1, x2, y2)'), contains('dist(v1, v2)')),
          ),
        ),
      );
      // Vectors *and* trailing coordinates.
      expect(() => engine.dist(v, v, 3, 4), throwsArgumentError);
      expect(() => engine.distSq(v, v, 3, 4), throwsArgumentError);
      // Mixed shapes.
      expect(() => engine.dist(v, 2, 3, 4), throwsArgumentError);
      expect(() => engine.distSq(1, 2), throwsArgumentError);
    });
  });

  group('Simplex noise (default mode)', () {
    test('returns values in [-1, 1] for 1-D inputs', () {
      final engine = Flut5Engine();
      for (double x = -10; x <= 10; x += 0.37) {
        final v = engine.noise(x);
        expect(
          v,
          greaterThanOrEqualTo(-1.0),
          reason: 'noise($x) = $v is below -1',
        );
        expect(v, lessThanOrEqualTo(1.0), reason: 'noise($x) = $v is above 1');
      }
    });

    test('returns values in [-1, 1] for 2-D inputs', () {
      final engine = Flut5Engine();
      for (double x = -5; x <= 5; x += 0.73) {
        for (double y = -5; y <= 5; y += 0.73) {
          final v = engine.noise(x, y);
          expect(v, greaterThanOrEqualTo(-1.0));
          expect(v, lessThanOrEqualTo(1.0));
        }
      }
    });

    test('returns values in [-1, 1] for 3-D inputs', () {
      final engine = Flut5Engine();
      for (double x = -3; x <= 3; x += 1.1) {
        for (double y = -3; y <= 3; y += 1.1) {
          for (double z = -3; z <= 3; z += 1.1) {
            final v = engine.noise(x, y, z);
            expect(v, greaterThanOrEqualTo(-1.0));
            expect(v, lessThanOrEqualTo(1.0));
          }
        }
      }
    });

    test('is deterministic with same seed', () {
      final a = Flut5Engine()..noiseSeed(42);
      final b = Flut5Engine()..noiseSeed(42);
      for (double x = 0; x < 5; x += 0.5) {
        expect(
          a.noise(x, x * 0.3, x * 0.7),
          equals(b.noise(x, x * 0.3, x * 0.7)),
        );
      }
    });

    test('different seeds produce different values', () {
      final a = Flut5Engine()..noiseSeed(1);
      final b = Flut5Engine()..noiseSeed(2);
      bool anyDifferent = false;
      for (double x = 0; x < 5; x += 0.5) {
        if (a.noise(x) != b.noise(x)) {
          anyDifferent = true;
          break;
        }
      }
      expect(anyDifferent, isTrue);
    });

    test('adjacent inputs produce smooth values', () {
      final engine = Flut5Engine();
      const step = 0.001;
      for (double x = 0; x < 1; x += 0.1) {
        final v1 = engine.noise(x);
        final v2 = engine.noise(x + step);
        expect(
          (v1 - v2).abs(),
          lessThan(0.05),
          reason: 'Discontinuity at x=$x',
        );
      }
    });
  });

  // ── Perlin noise ─────────────────────────────────────────────────────

  group('Perlin noise (via noiseMode)', () {
    test('returns values in [0, 1]', () {
      final engine = Flut5Engine()..noiseMode = NoiseMode.perlin;
      engine.noiseSeed(42);
      for (double x = 0; x < 10; x += 0.37) {
        final v = engine.noise(x);
        expect(v, greaterThanOrEqualTo(0.0));
        expect(v, lessThanOrEqualTo(1.0));
      }
    });

    test('is deterministic with same seed', () {
      final a = Flut5Engine()
        ..noiseMode = NoiseMode.perlin
        ..noiseSeed(99);
      final b = Flut5Engine()
        ..noiseMode = NoiseMode.perlin
        ..noiseSeed(99);
      for (double x = 0; x < 5; x += 0.5) {
        expect(a.noise(x), equals(b.noise(x)));
      }
    });
  });

  // ── Mode independence ────────────────────────────────────────────────

  group('Mode independence', () {
    test('noiseDetail in simplex does not affect perlin', () {
      final engine = Flut5Engine()
        ..noiseMode = NoiseMode.perlin
        ..noiseSeed(7);
      final before = engine.noise(1.23, 4.56);

      engine.noiseMode = NoiseMode.simplex;
      engine.noiseDetail(8, 0.8);

      engine.noiseMode = NoiseMode.perlin;
      final after = engine.noise(1.23, 4.56);
      expect(before, equals(after));
    });

    test('noiseDetail in perlin does not affect simplex', () {
      final engine = Flut5Engine()..noiseSeed(7);
      final before = engine.noise(1.23, 4.56);

      engine.noiseMode = NoiseMode.perlin;
      engine.noiseDetail(8, 0.8);

      engine.noiseMode = NoiseMode.simplex;
      final after = engine.noise(1.23, 4.56);
      expect(before, equals(after));
    });

    test('resetNoise only resets the active mode', () {
      final engine = Flut5Engine();
      // Collect simplex defaults.
      const samples = [1.0, 2.3, 4.7, 6.1, 8.9];
      final simplexDefaults = [
        for (final s in samples) engine.noise(s, s * 0.5),
      ];

      // Seed simplex.
      engine.noiseSeed(999);

      // Reset only perlin (switch mode, reset, switch back).
      engine.noiseMode = NoiseMode.perlin;
      engine.resetNoise();
      engine.noiseMode = NoiseMode.simplex;

      // Simplex should still be seeded (not reset).
      final afterPerlinReset = [
        for (final s in samples) engine.noise(s, s * 0.5),
      ];
      // At least one value should differ from defaults (still seeded).
      bool anyDifferent = false;
      for (int i = 0; i < samples.length; i++) {
        if (simplexDefaults[i] != afterPerlinReset[i]) {
          anyDifferent = true;
          break;
        }
      }
      expect(
        anyDifferent,
        isTrue,
        reason: 'Simplex should still be seeded after resetting perlin',
      );
    });
  });

  group('Sketch pointer events', () {
    test('hover events expose current and previous local positions', () async {
      final events = Flut5Event();
      final emitted = events.pointerMoveStream.take(2).toList();

      events.addPointerHover(const PointerHoverEvent(position: Offset(10, 20)));
      events.addPointerHover(const PointerHoverEvent(position: Offset(16, 28)));

      final pointerEvents = await emitted;
      expect(pointerEvents, hasLength(2));
      expect(pointerEvents[0].location, const Offset(10, 20));
      expect(pointerEvents[0].plocation, const Offset(10, 20));
      expect(pointerEvents[1].location, const Offset(16, 28));
      expect(pointerEvents[1].plocation, const Offset(10, 20));

      events.dispose();
    });

    test('move events expose current and previous local positions', () async {
      final events = Flut5Event();
      final emitted = events.pointerMoveStream.take(2).toList();

      events.addPointerMove(const PointerMoveEvent(position: Offset(10, 20)));
      events.addPointerMove(const PointerMoveEvent(position: Offset(16, 28)));

      final pointerEvents = await emitted;
      expect(pointerEvents, hasLength(2));
      expect(pointerEvents[0].location, const Offset(10, 20));
      expect(pointerEvents[0].plocation, const Offset(10, 20));
      expect(pointerEvents[1].location, const Offset(16, 28));
      expect(pointerEvents[1].plocation, const Offset(10, 20));

      events.dispose();
    });

    test('engine mouse variables update on hover, move, and drag', () {
      final engine = Flut5Engine();

      engine.events.addPointerHover(
        const PointerHoverEvent(position: Offset(6, 8)),
      );

      expect(engine.mouseX, 6.0);
      expect(engine.mouseY, 8.0);
      expect(engine.pmouseX, 6.0);
      expect(engine.pmouseY, 8.0);

      engine.events.addPointerMove(
        const PointerMoveEvent(position: Offset(10, 20)),
      );

      expect(engine.mouseX, 10.0);
      expect(engine.mouseY, 20.0);
      expect(engine.pmouseX, 6.0);
      expect(engine.pmouseY, 8.0);

      engine.events.addPointerDown(
        const PointerDownEvent(position: Offset(10, 20)),
      );
      engine.events.addPointerMove(
        const PointerMoveEvent(position: Offset(16, 28)),
      );

      expect(engine.mouseX, 16.0);
      expect(engine.mouseY, 28.0);
      expect(engine.pmouseX, 10.0);
      expect(engine.pmouseY, 20.0);

      engine.events.dispose();
    });

    test('drag and up events reuse the previous local position', () async {
      final events = Flut5Event();
      final downFuture = events.pointerDownStream.first;
      final dragFuture = events.pointerDraggedStream.first;
      final upFuture = events.pointerUpStream.first;

      events.addPointerDown(const PointerDownEvent(position: Offset(4, 6)));
      events.addPointerMove(const PointerMoveEvent(position: Offset(7, 11)));
      events.addPointerUp(const PointerUpEvent(position: Offset(9, 13)));

      final down = await downFuture;
      final drag = await dragFuture;
      final up = await upFuture;

      expect(down.location, const Offset(4, 6));
      expect(down.plocation, const Offset(4, 6));
      expect(drag.location, const Offset(7, 11));
      expect(drag.plocation, const Offset(4, 6));
      expect(up.location, const Offset(9, 13));
      expect(up.plocation, const Offset(7, 11));

      events.dispose();
    });
  });

  group('Sketch keyboard events', () {
    test(
      'key down emits pressed and typed events with key and keyCode',
      () async {
        final events = Flut5Event();
        final pressedFuture = events.keyPressedStream.first;
        final typedFuture = events.keyTypedStream.first;

        events.addKeyEvent(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyA,
            logicalKey: LogicalKeyboardKey.keyA,
            character: 'a',
            timeStamp: Duration.zero,
          ),
        );

        final pressed = await pressedFuture;
        final typed = await typedFuture;

        expect(pressed.key, 'a');
        expect(pressed.keyCode, 65);
        expect(pressed.logicalKey, LogicalKeyboardKey.keyA);
        expect(pressed.physicalKey, PhysicalKeyboardKey.keyA);
        expect(pressed.rawEvent, isA<KeyDownEvent>());
        expect(pressed.repeat, isFalse);
        expect(typed.key, 'a');
        expect(typed.keyCode, 65);

        events.dispose();
      },
    );

    test('key up emits released events with the logical key label', () async {
      final events = Flut5Event();
      final releasedFuture = events.keyReleasedStream.first;

      events.addKeyEvent(
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.escape,
          logicalKey: LogicalKeyboardKey.escape,
          timeStamp: Duration.zero,
        ),
      );

      final released = await releasedFuture;

      expect(released.key, 'Escape');
      expect(released.keyCode, 27);
      expect(released.rawEvent, isA<KeyUpEvent>());

      events.dispose();
    });

    test('non-printable keys do not emit typed events', () async {
      final events = Flut5Event();
      var typed = false;
      final sub = events.keyTypedStream.listen((_) {
        typed = true;
      });

      events.addKeyEvent(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.escape,
          logicalKey: LogicalKeyboardKey.escape,
          timeStamp: Duration.zero,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(typed, isFalse);

      await sub.cancel();
      events.dispose();
    });

    test('engine key and keyCode track latest keyboard event', () {
      final engine = Flut5Engine();

      engine.events.addKeyEvent(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.arrowLeft,
          logicalKey: LogicalKeyboardKey.arrowLeft,
          timeStamp: Duration.zero,
        ),
      );

      expect(engine.key, 'Arrow Left');
      expect(engine.keyCode, 37);

      engine.events.dispose();
    });
  });

  group('Wheel buffer and Flut5Touch.kind', () {
    test(
      'addPointerScroll accumulates a sample and emits on scrollStream',
      () async {
        final events = Flut5Event();
        final scrollFuture = events.scrollStream.first;

        events.addPointerScroll(
          const PointerScrollEvent(
            position: Offset(50, 60),
            scrollDelta: Offset(4, 12),
          ),
        );
        events.addPointerScroll(
          const PointerScrollEvent(
            position: Offset(52, 64),
            scrollDelta: Offset(1, 8),
          ),
        );

        final sample = events.pendingWheel;
        expect(sample, isNotNull);
        // Deltas accumulate; position tracks the latest event.
        expect(sample!.dx, 5);
        expect(sample.dy, 20);
        expect(sample.x, 52);
        expect(sample.y, 64);

        final emitted = await scrollFuture;
        expect(emitted.location, const Offset(50, 60));
        expect(emitted.scrollDelta.x, 4);
        expect(emitted.scrollDelta.y, 12);

        events.clearPendingWheel();
        expect(events.pendingWheel, isNull);

        events.dispose();
      },
    );

    test('Flut5Touch.kind defaults to touch and tracks the pointer device', () {
      final engine = Flut5Engine();
      expect(
        Flut5Touch(id: 0, x: 0, y: 0, px: 0, py: 0).kind,
        PointerDeviceKind.touch,
      );

      engine.events.addPointerDown(
        const PointerDownEvent(
          pointer: 7,
          kind: PointerDeviceKind.mouse,
          position: Offset(5, 5),
        ),
      );
      expect(engine.touches.single.kind, PointerDeviceKind.mouse);

      engine.events.dispose();
    });
  });

  group('Container scroll-wheel and input mode', () {
    // Reads the scroll translate the container inserts (the last translate in
    // the queue; the render callback below draws no transforms of its own).
    Offset scrollOffset(Flut5Engine engine) {
      TransformRenderItem? last;
      for (final item in engine.renderQueue.items) {
        if (item is TransformRenderItem &&
            item.type == TransformType.translate) {
          last = item;
        }
      }
      final t = last!;
      return Offset(t.dx!, t.dy!);
    }

    // Runs one container frame at (0,0,100,100) with 400×400 content (so there
    // is room to scroll), then returns the resulting scroll offset.
    Offset frame(Flut5Engine engine) {
      engine.renderQueue.clear();
      engine.beginContainer(0, 0, 100, 100, {'id': 'box'});
      engine.rect(0, 0, 400, 400);
      engine.endContainer();
      return scrollOffset(engine);
    }

    PointerScrollEvent wheel(double dx, double dy) => PointerScrollEvent(
      position: const Offset(50, 50),
      scrollDelta: Offset(dx, dy),
    );

    test('wheel over a clamp container pans content opposite to the delta', () {
      final engine = Flut5Engine();
      engine.containerOverflow(Flut5ContainerOverflow.scroll);
      engine.containerOverscrollMode(Flut5ContainerOverscroll.clamp);

      engine.events.addPointerScroll(wheel(0, 50));
      // Wheel-down (positive dy) moves content up → negative offsetY.
      expect(frame(engine).dy, -50);

      // A large wheel is clamped to the content edge: loY = h - bottom = -300.
      engine.events.clearPendingWheel();
      engine.events.addPointerScroll(wheel(0, 1000));
      expect(frame(engine).dy, -300);

      engine.events.dispose();
    });

    test('horizontal wheel pans the X axis', () {
      final engine = Flut5Engine();
      engine.containerOverflow(Flut5ContainerOverflow.scroll);
      engine.containerOverscrollMode(Flut5ContainerOverscroll.clamp);

      engine.events.addPointerScroll(wheel(30, 0));
      expect(frame(engine).dx, -30);

      engine.events.dispose();
    });

    test('free mode lets the wheel scroll past the content bounds', () {
      final engine = Flut5Engine();
      engine.containerOverflow(Flut5ContainerOverflow.scroll);
      engine.containerOverscrollMode(Flut5ContainerOverscroll.free);

      engine.events.addPointerScroll(wheel(0, 5000));
      expect(frame(engine).dy, -5000);

      engine.events.dispose();
    });

    test('DRAG input mode ignores the wheel', () {
      final engine = Flut5Engine();
      engine.containerOverflow(Flut5ContainerOverflow.scroll);
      engine.containerOverscrollMode(Flut5ContainerOverscroll.clamp);
      engine.containerOverscrollInput(Flut5ContainerOverscrollInput.drag);

      engine.events.addPointerScroll(wheel(0, 50));
      expect(frame(engine).dy, 0);

      engine.events.dispose();
    });

    test('SCROLL input mode blocks mouse drag but keeps touch drag', () {
      // Mouse drag: should NOT move the content under SCROLL mode.
      final mouseEngine = Flut5Engine();
      mouseEngine.containerOverflow(Flut5ContainerOverflow.scroll);
      mouseEngine.containerOverscrollMode(Flut5ContainerOverscroll.clamp);
      mouseEngine.containerOverscrollInput(
        Flut5ContainerOverscrollInput.scroll,
      );

      mouseEngine.events.addPointerDown(
        const PointerDownEvent(
          pointer: 1,
          kind: PointerDeviceKind.mouse,
          position: Offset(50, 50),
        ),
      );
      frame(mouseEngine); // grab attempt (skipped for mouse)
      mouseEngine.events.addPointerMove(
        const PointerMoveEvent(
          pointer: 1,
          kind: PointerDeviceKind.mouse,
          position: Offset(50, 20),
        ),
      );
      expect(frame(mouseEngine).dy, 0);
      mouseEngine.events.dispose();

      // Touch drag: should still move the content under SCROLL mode.
      final touchEngine = Flut5Engine();
      touchEngine.containerOverflow(Flut5ContainerOverflow.scroll);
      touchEngine.containerOverscrollMode(Flut5ContainerOverscroll.clamp);
      touchEngine.containerOverscrollInput(
        Flut5ContainerOverscrollInput.scroll,
      );

      touchEngine.events.addPointerDown(
        const PointerDownEvent(
          pointer: 2,
          kind: PointerDeviceKind.touch,
          position: Offset(50, 50),
        ),
      );
      frame(touchEngine); // grab
      touchEngine.events.addPointerMove(
        const PointerMoveEvent(
          pointer: 2,
          kind: PointerDeviceKind.touch,
          position: Offset(50, 20),
        ),
      );
      // Dragging up moves content up → negative offsetY.
      expect(frame(touchEngine).dy, lessThan(0));
      touchEngine.events.dispose();
    });
  });

  group('Text metrics', () {
    test('textAscent/textDescent report font metrics at the current size', () {
      TestWidgetsFlutterBinding.ensureInitialized();
      final engine = Flut5Engine();
      engine.textSize(100);

      // The FlutterTest environment font has ascent 0.75em, descent 0.25em.
      expect(engine.textAscent(), closeTo(75, 0.001));
      expect(engine.textDescent(), closeTo(25, 0.001));

      // Scales linearly with textSize.
      engine.textSize(200);
      expect(engine.textAscent(), closeTo(150, 0.001));
      expect(engine.textDescent(), closeTo(50, 0.001));
    });
  });
}

final Set<String> _loadedTestFonts = {};

Future<void> _loadTestFont(String family, String path) async {
  if (!_loadedTestFonts.add(family)) return;
  final bytes = await File(path).readAsBytes();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}

Future<_AlphaBounds> _imageAlphaBounds(ui.Image image) async {
  final bytes = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );

  var minX = image.width;
  var minY = image.height;
  var maxX = -1;
  var maxY = -1;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final alpha = bytes!.getUint8((y * image.width + x) * 4 + 3);
      if (alpha == 0) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }

  if (maxX < 0) {
    throw StateError('Rendered image has no non-transparent pixels.');
  }
  return _AlphaBounds(minX, minY, maxX, maxY);
}

Future<_Pixel> _renderPixel(
  Flut5Engine engine,
  int width,
  int height, {
  required int x,
  required int y,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  engine.renderQueue.execute(canvas);
  final image = await recorder.endRecording().toImage(width, height);
  addTearDown(image.dispose);
  final bytes = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  final offset = (y * width + x) * 4;
  return _Pixel(
    bytes!.getUint8(offset),
    bytes.getUint8(offset + 1),
    bytes.getUint8(offset + 2),
    bytes.getUint8(offset + 3),
  );
}

Future<_AlphaBounds> _renderAlphaBounds(
  Flut5Engine engine,
  int width,
  int height,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  engine.renderQueue.execute(canvas);
  final image = await recorder.endRecording().toImage(width, height);
  addTearDown(image.dispose);
  final bytes = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );

  var minX = width;
  var minY = height;
  var maxX = -1;
  var maxY = -1;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final alpha = bytes!.getUint8((y * width + x) * 4 + 3);
      if (alpha == 0) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }

  if (maxX < 0) {
    throw StateError('Rendered image has no non-transparent pixels.');
  }
  return _AlphaBounds(minX, minY, maxX, maxY);
}

class const _AlphaBounds(
  final int minX,
  final int minY,
  final int maxX,
  final int maxY,
) {
  int get width => maxX - minX + 1;
}

class const _Pixel(
  final int red,
  final int green,
  final int blue,
  final int alpha,
);

Uint8List _type2CharString(List<int> numbers) {
  int encode(int value) {
    if (value >= -107 && value <= 107) return value + 139;
    throw ArgumentError.value(value, 'value', 'must fit compact Type 2 range');
  }

  return Uint8List.fromList([
    encode(numbers[0]),
    encode(numbers[1]),
    21, // rmoveto
    ...numbers.skip(2).map(encode),
    12,
    37, // flex1
    14, // endchar
  ]);
}

double _minGap(List<Flut5Vector> points) {
  var minGap = double.infinity;
  for (int i = 1; i < points.length; i++) {
    final dx = points[i].x - points[i - 1].x;
    final dy = points[i].y - points[i - 1].y;
    minGap = math.min(minGap, math.sqrt(dx * dx + dy * dy));
  }
  return minGap;
}
