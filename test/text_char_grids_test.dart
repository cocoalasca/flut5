import 'package:flut5/flut5.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/painting.dart' show FontWeight, FontStyle;

class _GridSketch({super.flut5}) extends Flut5;

const _square = <PathCommand>[
  MoveToCommand(0, 0),
  LineToCommand(100, 0),
  LineToCommand(100, 100),
  LineToCommand(0, 100),
  CloseCommand(),
];

Flut5Font _font({int advance = 137}) => Flut5Font.internal(
  unitsPerEm: 100,
  numGlyphs: 4,
  numberOfHMetrics: 4,
  charToGlyph: const {120: 1, 79: 2, 105: 3, 0x1f600: 1},
  glyphs: [
    Flut5Glyph.empty,
    Flut5Glyph(commands: _square, xMin: 0, yMin: 0, xMax: 100, yMax: 100),
    Flut5Glyph(
      commands: [
        ..._square,
        // Opposite winding leaves the counter empty.
        const MoveToCommand(20, 20),
        const LineToCommand(20, 80),
        const LineToCommand(80, 80),
        const LineToCommand(80, 20),
        const CloseCommand(),
      ],
      xMin: 0,
      yMin: 0,
      xMax: 100,
      yMax: 100,
    ),
    Flut5Glyph(
      commands: const [
        MoveToCommand(0, 0),
        LineToCommand(20, 0),
        LineToCommand(20, 60),
        LineToCommand(0, 60),
        CloseCommand(),
        MoveToCommand(0, 80),
        LineToCommand(20, 80),
        LineToCommand(20, 100),
        LineToCommand(0, 100),
        CloseCommand(),
      ],
      xMin: 0,
      yMin: 0,
      xMax: 20,
      yMax: 100,
    ),
  ],
  advanceWidths: [50, advance, advance, 40],
  lsbs: const [0, 0, 0, 0],
  axes: const [
    Flut5FontAxis(
      tag: 'wght',
      name: 'Weight',
      minValue: 100,
      defaultValue: 400,
      maxValue: 900,
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('character cells align with and reconstruct the whole grid', () {
    final font = _font();
    for (final spacing in [-150.0, -30.25, 0.0, 3.125]) {
      for (final cell in [4.0, 10.0, 13.7]) {
        const text = 'xOi\nx x';
        final chars = font.textToCharGrids(
          text,
          11.3,
          17.9,
          73,
          cellSize: cell,
          letterSpacing: spacing,
          lineHeight: 112.5,
        );
        final grid = font.textToGrid(
          text,
          11.3,
          17.9,
          73,
          cellSize: cell,
          letterSpacing: spacing,
          lineHeight: 112.5,
        );
        expect(chars.length, text.runes.length);
        final union = <(int, int)>{};
        for (final char in chars) {
          for (final pixel in char.filledCells) {
            final col = ((pixel.anchorX - grid.x) / cell).round();
            final row = ((pixel.anchorY - grid.y) / cell).round();
            expect(pixel.anchorX, closeTo(grid.xAt(col), 1e-9));
            expect(pixel.anchorY, closeTo(grid.yAt(row), 1e-9));
            union.add((col, row));
          }
        }
        expect(union, {
          for (final pixel in grid.filledCells) (pixel.col, pixel.row),
        });
      }
    }
  });

  test('holes and disconnected parts remain within their character', () {
    final chars = _font().textToCharGrids('Oi', 0, 0, 100, cellSize: 10);
    expect(chars, hasLength(2));
    expect(chars.first.stateAt(5, 5), Flut5CellState.empty);
    final i = chars.last;
    expect(i.stateAt(1, 0).isFilled, isTrue);
    expect(i.stateAt(1, 3), Flut5CellState.empty);
    expect(i.stateAt(1, 7).isFilled, isTrue);
  });

  test('spacing and newlines retain source indices and reset line start', () {
    final chars = _font(advance: 100).textToCharGrids(
      'x x\r\nx\n\nx😀',
      0,
      0,
      100,
      cellSize: 10,
      letterSpacing: 10,
      lineHeight: 150,
    );
    expect(chars, hasLength(10));
    for (final index in [1, 3, 4, 6, 7]) {
      expect(chars[index].isEmpty, isTrue);
    }
    expect(chars[2].x, 170);
    expect(chars[5].x, 0);
    expect(chars[5].y, 50);
    expect(chars[8].y, 350);
    expect(chars[9].x, 110);
    expect(_font().textToCharGrids('', 0, 0, 100), isEmpty);
    expect(
      _font().textToCharGrids(' \n ', 0, 0, 100),
      everyElement(predicate<Flut5TextGrid>((grid) => grid.isEmpty)),
    );
  });

  test('cache shares immutable arrays across calls and translations', () {
    final font = _font();
    final a = font.textToCharGrids('xO', 0, 0, 100);
    final b = font.textToCharGrids('xO', 200, -50, 100);
    expect(identical(a, font.textToCharGrids('xO', 0, 0, 100)), isTrue);
    for (var i = 0; i < a.length; i++) {
      expect(identical(a[i].states, b[i].states), isTrue);
      expect(b[i].x, a[i].x + 200);
      expect(b[i].y, a[i].y - 50);
    }
    final grid = font.textToGrid('xO', 0, 0, 100);
    expect(
      identical(grid.states, font.textToGrid('xO', 12, 5, 100).states),
      isTrue,
    );
    expect(() => a.clear(), throwsUnsupportedError);
    expect(() => a.first.states.clear(), throwsUnsupportedError);
    expect(
      () => a.first.states.first[0] = Flut5CellState.empty,
      throwsUnsupportedError,
    );
    final single = font.textToCharGrids('x', 0, 0, 100).single;
    expect(
      identical(single.states, font.textToGrid('x', 0, 0, 100).states),
      isTrue,
    );
  });

  test('cache distinguishes layout inputs, fonts and variation axes', () {
    final font = _font();
    final initial = font.textToCharGrids('xx', 0, 0, 100);
    for (final other in [
      font.textToCharGrids('xO', 0, 0, 100),
      font.textToCharGrids('xx', 0, 0, 50),
      font.textToCharGrids('xx', 0, 0, 100, cellSize: 8),
      font.textToCharGrids('xx', 0, 0, 100, letterSpacing: 11),
      font.textToCharGrids('xx', 0, 0, 100, lineHeight: 120),
      _font(advance: 160).textToCharGrids('xx', 0, 0, 100),
    ]) {
      expect(identical(initial.first.states, other.first.states), isFalse);
    }
    font.setAxisValue('wght', 800);
    expect(
      identical(
        initial.first.states,
        font.textToCharGrids('xx', 0, 0, 100).first.states,
      ),
      isFalse,
    );
    font.resetAxisValues();
    expect(identical(initial, font.textToCharGrids('xx', 0, 0, 100)), isTrue);
  });

  test('cache evicts old layouts while keeping recently used entries', () {
    final font = _font();
    final old = font.textToCharGrids('x', 0, 0, 100);
    final hot = font.textToCharGrids('O', 0, 0, 100);
    for (var i = 0; i < 40; i++) {
      font.textToCharGrids('i', 0, 0, 30.0 + i);
      font.textToCharGrids('O', 0, 0, 100);
    }
    expect(identical(hot, font.textToCharGrids('O', 0, 0, 100)), isTrue);
    expect(identical(old, font.textToCharGrids('x', 0, 0, 100)), isFalse);
  });

  test('cache bounds retained cell data and bypasses oversized grids', () {
    final font = _font();
    final first = font.textToCharGrids('x', 0, 0, 250, cellSize: 1);
    for (var i = 1; i <= 9; i++) {
      font.textToCharGrids(
        'x',
        0,
        0,
        250,
        cellSize: 1,
        letterSpacing: i.toDouble(),
      );
    }
    expect(
      identical(first, font.textToCharGrids('x', 0, 0, 250, cellSize: 1)),
      isFalse,
    );
    final large = font.textToCharGrids('x', 0, 0, 710, cellSize: 1);
    expect(large.single.cols, 710);
    expect(
      identical(large, font.textToCharGrids('x', 0, 0, 710, cellSize: 1)),
      isFalse,
    );
  });

  test('default multiline leading uses registered font metrics', () {
    final font = _font();
    final engine = Flut5Engine();
    engine.environment = engine.environment.withFonts({
      'GridTest': Flut5FontData(name: 'GridTest', asset: '', font: font),
    });
    engine.textFont('GridTest');
    engine.textSize(100);
    final height = Flut5TextCache.instance.measureLineHeight(
      fontFamily: 'GridTest',
      fontSize: 100,
      fontWeight: FontWeight.normal,
      fontStyle: FontStyle.normal,
    );
    final actual = engine.textToCharGrids('x\nx', 0, 0);
    final expected = font.textToCharGrids(
      'x\nx',
      0,
      0,
      100,
      lineHeight: height,
    );
    expect(actual[2].y, expected[2].y);
    expect(identical(actual[2].states, expected[2].states), isTrue);
    final sketch = _GridSketch(flut5: engine);
    expect(sketch.textToCharGrids('x\nx', 0, 0), same(actual));
  });

  test('engine forwards settings and per-call overrides to both APIs', () {
    final font = _font(advance: 100);
    final engine = Flut5Engine()
      ..textSize(100)
      ..letterSpacing(10)
      ..textLeading(150);
    final args = <String, dynamic>{
      Flut5TextArg.font: font,
      Flut5TextArg.cellSize: 10,
    };
    final chars = engine.textToCharGrids('xx\nx', 40, 200, args: args);
    expect(chars[1].x, 150);
    expect(chars[3].y, 250);
    final override = {
      ...args,
      Flut5TextArg.letterSpacing: 20,
      Flut5TextArg.lineHeight: 180,
    };
    final changed = engine.textToCharGrids('xx\nx', 40, 200, args: override);
    expect(changed[1].x, 160);
    expect(changed[3].y, 280);
    expect(engine.textToGrid('xx\nx', 40, 200, args: override).height, 280);
    final again = engine.textToCharGrids('xx\nx', 40, 200, args: args);
    expect(identical(chars[0].states, again[0].states), isTrue);
    expect(Flut5Engine().textToCharGrids('x', 0, 0), isEmpty);
  });
}
