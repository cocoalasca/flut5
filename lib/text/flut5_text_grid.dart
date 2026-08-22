import 'dart:ui' show Rect;

import '../math/flut5_vector.dart';

// ── Text grid ─────────────────────────────────────────────────────────

/// State of a single cell in a [Flut5TextGrid].
enum Flut5CellState {
  /// The cell lies entirely outside the glyph outlines.
  empty,

  /// The cell carries the glyph and is walled in by filled cells on all four
  /// sides, so it sits in the body of a stroke rather than on its border.
  interior,

  /// The cell carries the glyph and touches the outside: it sits on the rim of
  /// the grid, or at least one of its four orthogonal neighbours is [empty].
  /// Edge cells count as filled too — [isFilled] is `true` for both.
  ///
  /// This is a neighbourhood test, not a coverage fraction: edge cells are the
  /// one-cell-thick outline of the filled shape, so they trace it cleanly even
  /// where a stroke runs several cells thick. A cell an outline merely clips on
  /// its way through a thick stroke is [interior], not edge — what matters is
  /// whether the cell borders empty space, not whether a curve grazed it.
  edge;

  /// Whether the cell carries any of the glyph — `true` for [interior] and
  /// [edge], `false` only for [empty].
  bool get isFilled => this != Flut5CellState.empty;
}

/// One cell of a [Flut5TextGrid], resolved with its own indices and its own
/// screen-space geometry.
///
/// Cells are **views**, built on demand by [Flut5TextGrid.cellAt],
/// [Flut5TextGrid.allCells], and [Flut5TextGrid.filledCells]. The grid itself
/// stores only [Flut5CellState]s, so a 250k-cell grid costs one pointer per
/// cell instead of one object — you pay for cells you actually pull, and a
/// lazy `.where(...).take(n)` allocates only what it yields.
///
/// Unlike a bare state, a cell stays usable once detached from its grid: it
/// carries [col]/[row] to feed back into lookups and [x]/[y]/[size] to draw
/// with, so filtered, sorted, and shuffled lists lose nothing.
///
/// ```dart
/// final targets = grid.filledCells.toList()..shuffle();
/// for (final cell in targets) {
///   flut5.fill(cell.state == Flut5CellState.edge ? Colors.red : Colors.white);
///   flut5.square(cell.anchorX, cell.anchorY, cell.size);
/// }
/// ```
final class Flut5TextCell {
  /// Column index within the grid, 0 being the leftmost.
  final int col;

  /// Row index within the grid, 0 being the top.
  final int row;

  /// Whether this cell is empty, interior, or crossed by an outline.
  final Flut5CellState state;

  /// Left edge of the cell in screen space — the x of [anchor].
  final double anchorX;

  /// Top edge of the cell in screen space — the y of [anchor].
  final double anchorY;

  /// Edge length of the cell in pixels — uniform across the whole grid.
  final double size;

  const Flut5TextCell({
    required this.col,
    required this.row,
    required this.state,
    required this.anchorX,
    required this.anchorY,
    required this.size,
  });

  /// Whether the cell carries any of the glyph — shorthand for
  /// `state.isFilled`, so it covers [Flut5CellState.interior] and
  /// [Flut5CellState.edge] alike.
  bool get isFilled => state.isFilled;

  /// Top-left corner of the cell in screen space.
  ///
  /// Feed this to the **corner-based** primitives — `rect` and `square` build
  /// a `Rect.fromLTWH`, so they want the corner. [anchorX]/[anchorY] are the
  /// same point without the allocation.
  ///
  /// A fresh [Flut5Vector] each call — [Flut5Vector] is mutable, so a stored
  /// and shared one could be edited out from under the grid.
  Flut5Vector get anchor => Flut5Vector(anchorX, anchorY);

  /// Center of the cell in screen space — the cell's position.
  ///
  /// Feed this to the **center-based** primitives — `circle` and `ellipse`
  /// build a `Rect.fromCenter`, so they want the middle. Passing [anchor]
  /// there instead shifts everything up-left by half a cell.
  ///
  /// A fresh [Flut5Vector] each call, for the same reason as [anchor].
  Flut5Vector get position =>
      Flut5Vector(anchorX + size / 2, anchorY + size / 2);

  /// The cell's square in screen space.
  Rect get bounds => Rect.fromLTWH(anchorX, anchorY, size, size);

  @override
  String toString() => 'Flut5TextCell($col, $row, ${state.name})';
}

/// A uniform grid sampled over the outlines of a string.
///
/// Produced by `textToGrid`. The grid covers the tight bounding box of the
/// rendered outline: cell `(0, 0)` sits at ([x], [y]), the box's top-left
/// corner, and rows run top-to-bottom in screen space (y-down). Note that
/// ([x], [y]) is the *outline's* box, not the baseline origin passed to
/// `textToGrid` — map cells back with [xAt]/[yAt] rather than that origin.
///
/// Two ways to read it, both always available:
///
/// - **States** — [states], [operator []], and [stateAt] hand back bare
///   [Flut5CellState]s with no allocation. Use these in per-frame loops.
/// - **Cells** — [cellAt], [allCells], and [filledCells] build [Flut5TextCell]
///   views that carry their own coordinates, so they stay meaningful after
///   being filtered, sorted, or stored. Use these at setup time and anywhere
///   a cell outlives the loop that found it.
///
/// ```dart
/// // Ergonomic: each cell knows where it is.
/// for (final cell in grid.filledCells) {
///   flut5.fill(cell.state == Flut5CellState.edge ? Colors.red : Colors.white);
///   flut5.square(cell.anchorX, cell.anchorY, cell.size);
/// }
///
/// // Allocation-free: indices only.
/// for (int r = 0; r < grid.rows; r++) {
///   final row = grid.states[r];
///   for (int c = 0; c < grid.cols; c++) {
///     if (!row[c].isFilled) continue;
///     flut5.square(grid.xAt(c), grid.yAt(r), grid.cellSize);
///   }
/// }
/// ```
class Flut5TextGrid {
  /// Cell states indexed `[row][col]`, row 0 being the top of the box.
  final List<List<Flut5CellState>> states;

  /// Left edge of column 0 in screen space.
  final double x;

  /// Top edge of row 0 in screen space.
  final double y;

  /// Edge length of one cell in pixels.
  final double cellSize;

  const Flut5TextGrid({
    required this.states,
    required this.x,
    required this.y,
    required this.cellSize,
  });

  /// A grid with no cells, returned when the text has no drawable outline.
  static const Flut5TextGrid empty = Flut5TextGrid(
    states: [],
    x: 0,
    y: 0,
    cellSize: 0,
  );

  /// Number of rows.
  int get rows => states.length;

  /// Number of columns.
  int get cols => states.isEmpty ? 0 : states.first.length;

  /// Total width covered by the grid in pixels.
  double get width => cols * cellSize;

  /// Total height covered by the grid in pixels.
  double get height => rows * cellSize;

  /// Whether the grid has no cells at all.
  bool get isEmpty => states.isEmpty;

  // ── State access (allocation-free) ──────────────────────────────────

  /// Row [row] of [states], so `grid[row][col]` works.
  ///
  /// Row-major like the backing array — note the axis order is the reverse
  /// of [stateAt] and [cellAt], which both take `(col, row)`.
  List<Flut5CellState> operator [](int row) => states[row];

  /// Cell state at ([col], [row]), returning [Flut5CellState.empty] for
  /// out-of-range indices instead of throwing.
  ///
  /// The safe out-of-range answer makes neighbor lookups bounds-check-free —
  /// no row/column special-casing at the rim:
  ///
  /// ```dart
  /// int filledNeighbors(int c, int r) => [
  ///   grid.stateAt(c - 1, r), grid.stateAt(c + 1, r),
  ///   grid.stateAt(c, r - 1), grid.stateAt(c, r + 1),
  /// ].where((s) => s.isFilled).length;
  /// ```
  ///
  /// That neighborhood is what splits [Flut5CellState.edge] from
  /// [Flut5CellState.interior] in the first place, so reach for the state
  /// itself before recomputing it — a filled cell is edge exactly when
  /// `filledNeighbors` is under 4.
  Flut5CellState stateAt(int col, int row) {
    if (row < 0 || row >= rows || col < 0 || col >= cols) {
      return Flut5CellState.empty;
    }
    return states[row][col];
  }

  // ── Cell access (one object per cell pulled) ────────────────────────

  /// The cell at ([col], [row]) as a [Flut5TextCell].
  ///
  /// Out-of-range indices come back as [Flut5CellState.empty] cells rather
  /// than throwing, matching [stateAt]. Their geometry still resolves — it is
  /// where that cell *would* sit if the grid extended that far.
  Flut5TextCell cellAt(int col, int row) => Flut5TextCell(
    col: col,
    row: row,
    state: stateAt(col, row),
    anchorX: xAt(col),
    anchorY: yAt(row),
    size: cellSize,
  );

  /// Every cell in the grid, row by row from the top, left to right.
  ///
  /// Lazy — cells are built as they are yielded, so `allCells.take(50)`
  /// allocates 50 objects, not `rows * cols`.
  Iterable<Flut5TextCell> get allCells sync* {
    for (int r = 0; r < rows; r++) {
      final row = states[r];
      final double cellY = yAt(r);
      for (int c = 0; c < row.length; c++) {
        yield Flut5TextCell(
          col: c,
          row: r,
          state: row[c],
          anchorX: xAt(c),
          anchorY: cellY,
          size: cellSize,
        );
      }
    }
  }

  /// Every cell carrying part of the glyph — [Flut5CellState.interior] and
  /// [Flut5CellState.edge] — in the same order as [allCells].
  ///
  /// Lazy, and the usual starting point: it skips the [Flut5CellState.isFilled]
  /// guard and, via `.toList()`, gives a detached list that still knows both
  /// what each cell is and where it sits.
  ///
  /// ```dart
  /// final outline = grid.filledCells
  ///     .where((c) => c.state == Flut5CellState.edge)
  ///     .toList();
  /// ```
  Iterable<Flut5TextCell> get filledCells sync* {
    for (int r = 0; r < rows; r++) {
      final row = states[r];
      final double cellY = yAt(r);
      for (int c = 0; c < row.length; c++) {
        final state = row[c];
        if (!state.isFilled) continue;
        yield Flut5TextCell(
          col: c,
          row: r,
          state: state,
          anchorX: xAt(c),
          anchorY: cellY,
          size: cellSize,
        );
      }
    }
  }

  // ── Geometry ────────────────────────────────────────────────────────

  /// Left edge of column [col] in screen space.
  double xAt(int col) => x + col * cellSize;

  /// Top edge of row [row] in screen space.
  double yAt(int row) => y + row * cellSize;

  /// Center of cell ([col], [row]) in screen space.
  Flut5Vector cellCenter(int col, int row) =>
      Flut5Vector(x + (col + 0.5) * cellSize, y + (row + 0.5) * cellSize);
}
