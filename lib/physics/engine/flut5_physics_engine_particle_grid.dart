part of 'flut5_physics_engine.dart';

/// Particles filed by position into square cells, so a collision pass only
/// looks at the particles near each other instead of at every pair.
///
/// A cell is as wide as the typical particle, so two filed particles can
/// only touch when they are in the same cell or in cells next to each
/// other. The few particles too big for a cell are kept out of it, in
/// [largeParticles], and are tested against everything instead — one giant
/// among thousands of small particles doesn't stretch the cells for all.
///
/// [file] rebuilds it from scratch, which costs a few passes over the
/// particles and nothing per pair. Collisions then move particles without
/// refiling them: a particle pushed across a cell border is found again on
/// the next pass.
final class _ParticleGrid() {
  /// How many cells the grid has across and down (dense mode).
  int columns = 1;
  int rows = 1;

  /// True when sparse/outlier particle coordinates caused the grid to switch
  /// to flat spatial hashing so [cellSize] stays tuned to particle radii
  /// instead of inflating and collapsing clustered particles to O(N²).
  bool isHashed = false;

  /// Side of a cell, in pixels. No filed particle's radius is more than
  /// half of it.
  double cellSize = 1;

  /// The biggest radius of any particle given to [file], `0` when none has
  /// one — then no two particles can touch.
  double largestRadius = 0;

  /// Where each cell's particles start in [filedParticles] (dense mode):
  /// cell `c` holds `filedParticles[cellStarts[c]]` up to, not including,
  /// `filedParticles[cellStarts[c + 1]]`.
  Int32List cellStarts = Int32List(0);

  /// Particle indices grouped by cell (dense mode), or filed particles in
  /// creation order (hashed mode, first [filedCount] entries).
  Int32List filedParticles = Int32List(0);
  int filedCount = 0;

  /// Hash table backing [isHashed] mode: bucket head -> particle index (-1 if
  /// empty), per-particle next pointer, and per-particle integer cell coords.
  Int32List hashHeads = Int32List(0);
  Int32List hashNext = Int32List(0);
  Int32List cellX = Int32List(0);
  Int32List cellY = Int32List(0);
  int _hashMask = 0;

  /// Indices of the particles too big for a cell, oldest first; the first
  /// [largeCount] entries count.
  Int32List largeParticles = Int32List(0);
  int largeCount = 0;

  // Where the grid starts, and the inverse of [cellSize].
  double _left = 0;
  double _top = 0;
  double _cellsPerPixel = 1;

  // Per particle: its cell, or one of the markers below.
  Int32List _cellOfParticle = Int32List(0);
  // Per cell: where its next particle goes while they are being placed.
  Int32List _nextSlotOfCell = Int32List(0);

  /// A particle that isn't anywhere a cell could hold: its position is
  /// infinite or not a number. It can't touch anything.
  static const int _nowhere = -1;
  static const int _tooLarge = -2;
  static const double _maxHashCoord = 1e9;

  /// Whether [particle] was kept out of the cells for being too big.
  bool isLarge(int particle) => _cellOfParticle[particle] == _tooLarge;

  /// Hash bucket index for integer cell `(cx, cy)` in [isHashed] mode.
  int hashSlot(int cx, int cy) => ((cx * 73856093) ^ (cy * 19349663)) & _hashMask;

  /// Unclamped integer cell column for [x] in [isHashed] mode.
  int hashColumnAt(double x) => ((x - _left) * _cellsPerPixel).floor();

  /// Unclamped integer cell row for [y] in [isHashed] mode.
  int hashRowAt(double y) => ((y - _top) * _cellsPerPixel).floor();

  /// Whether walking the hashed cells under this box is cheaper than walking
  /// every filed particle, and its corners can be turned into cell numbers.
  /// Also false for infinite or not-a-number coordinates.
  bool hashedBoxIsWalkable(
    double minX,
    double minY,
    double maxX,
    double maxY,
  ) {
    final columnsAcross = (maxX - minX) * _cellsPerPixel + 1;
    final rowsAcross = (maxY - minY) * _cellsPerPixel + 1;
    return columnsAcross * rowsAcross <= filedCount &&
        ((minX - _left) * _cellsPerPixel).abs() <= _maxHashCoord &&
        ((maxX - _left) * _cellsPerPixel).abs() <= _maxHashCoord &&
        ((minY - _top) * _cellsPerPixel).abs() <= _maxHashCoord &&
        ((maxY - _top) * _cellsPerPixel).abs() <= _maxHashCoord;
  }

  /// The column [x] falls in, or the nearest one if it is outside the grid.
  int columnAt(double x) => _nearestCell((x - _left) * _cellsPerPixel, columns);

  /// The row [y] falls in, or the nearest one if it is outside the grid.
  int rowAt(double y) => _nearestCell((y - _top) * _cellsPerPixel, rows);

  static int _nearestCell(double cell, int cellCount) {
    // Also true when it is not a number.
    if (!(cell > 0)) return 0;
    if (cell >= cellCount) return cellCount - 1;
    return cell.toInt();
  }

  /// Files the first [count] particles by their positions and radii.
  void file(
    int count,
    Float64List positionX,
    Float64List positionY,
    Float64List radius,
  ) {
    _sizeCells(count, positionX, positionY, radius);
    if (isHashed) {
      _fileHashed(count, positionX, positionY, radius);
      return;
    }
    final cellCount = columns * rows;
    _growLists(count, cellCount);
    _countParticlesPerCell(count, cellCount, positionX, positionY, radius);
    _placeParticles(count, cellCount);
  }

  /// Lays the grid over the particles: from the box around them and their
  /// typical radius, sets [cellSize], [columns] and [rows], switching to
  /// [isHashed] mode when particles are spread across outliers.
  void _sizeCells(
    int count,
    Float64List positionX,
    Float64List positionY,
    Float64List radius,
  ) {
    var left = double.infinity, top = double.infinity;
    var right = double.negativeInfinity, bottom = double.negativeInfinity;
    var radiusSum = 0.0;
    var largest = 0.0;
    var placedCount = 0;
    for (var i = 0; i < count; i++) {
      final x = positionX[i], y = positionY[i];
      if (!x.isFinite || !y.isFinite) continue;
      placedCount++;
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
      final particleRadius = radius[i];
      if (particleRadius > 0 && particleRadius.isFinite) {
        radiusSum += particleRadius;
        if (particleRadius > largest) largest = particleRadius;
      }
    }
    largestRadius = largest;

    final width = right - left, height = bottom - top;
    if (placedCount == 0 || !width.isFinite || !height.isFinite) {
      // Nothing to lay a grid over, or particles too far apart to measure:
      // one cell for everything.
      isHashed = false;
      _left = _top = 0;
      _cellsPerPixel = 0;
      cellSize = double.infinity;
      columns = rows = 1;
      return;
    }

    // A cell holds the typical particle. One sized for the biggest would
    // be crowded whenever a few particles are much bigger than the rest,
    // so those go to [largeParticles] instead.
    double size = 2 * math.min(largest, 2 * radiusSum / placedCount);
    // Points have no size to go by: about one per cell.
    if (size == 0) size = math.sqrt(width * height / placedCount);
    if (size == 0) size = math.max(width, height) / placedCount;
    if (size == 0) size = 1;

    // Dense 2D grid while compact; switch to flat spatial hash when sparse or
    // stretched by outliers so cellSize stays tuned to particle radii.
    final mostCells = 4.0 * count + 64;
    final wantedCells = (width / size + 1) * (height / size + 1);
    if (wantedCells > mostCells) {
      isHashed = true;
      _left = left;
      _top = top;
      cellSize = size;
      _cellsPerPixel = 1 / size;
      columns = rows = 0;
      return;
    }

    isHashed = false;
    _left = left;
    _top = top;
    cellSize = size;
    _cellsPerPixel = 1 / size;
    columns = (width * _cellsPerPixel).toInt() + 1;
    rows = (height * _cellsPerPixel).toInt() + 1;
  }

  void _fileHashed(
    int count,
    Float64List positionX,
    Float64List positionY,
    Float64List radius,
  ) {
    if (_cellOfParticle.length < count) {
      final cap = count * 2;
      _cellOfParticle = Int32List(cap);
      filedParticles = Int32List(cap);
      largeParticles = Int32List(cap);
      hashNext = Int32List(cap);
      cellX = Int32List(cap);
      cellY = Int32List(cap);
    } else if (hashNext.length < count) {
      final cap = _cellOfParticle.length;
      hashNext = Int32List(cap);
      cellX = Int32List(cap);
      cellY = Int32List(cap);
    }
    var slots = 64;
    final target = count * 2;
    while (slots < target) {
      slots <<= 1;
    }
    if (hashHeads.length < slots) {
      hashHeads = Int32List(slots);
    }
    hashHeads.fillRange(0, slots, -1);
    _hashMask = slots - 1;

    final cellOfParticle = _cellOfParticle;
    final largestFiledRadius = cellSize / 2;
    largeCount = 0;
    filedCount = 0;
    for (var i = 0; i < count; i++) {
      final x = positionX[i], y = positionY[i];
      if (!x.isFinite || !y.isFinite) {
        cellOfParticle[i] = _nowhere;
        continue;
      }
      final gx = (x - _left) * _cellsPerPixel;
      final gy = (y - _top) * _cellsPerPixel;
      if (radius[i] > largestFiledRadius ||
          gx.abs() > _maxHashCoord ||
          gy.abs() > _maxHashCoord) {
        cellOfParticle[i] = _tooLarge;
        largeParticles[largeCount++] = i;
        continue;
      }
      final cx = gx.floor();
      final cy = gy.floor();
      cellX[i] = cx;
      cellY[i] = cy;
      cellOfParticle[i] = 0;
      filedParticles[filedCount++] = i;
    }
    // Link in reverse so each hash bucket chain is in ascending creation order.
    for (var slot = filedCount - 1; slot >= 0; slot--) {
      final i = filedParticles[slot];
      final bucket = hashSlot(cellX[i], cellY[i]);
      hashNext[i] = hashHeads[bucket];
      hashHeads[bucket] = i;
    }
  }

  void _growLists(int count, int cellCount) {
    if (_cellOfParticle.length < count) {
      _cellOfParticle = Int32List(count * 2);
      filedParticles = Int32List(count * 2);
      largeParticles = Int32List(count * 2);
    }
    // One past the last cell, so the last cell has an end too.
    if (cellStarts.length < cellCount + 1) {
      cellStarts = Int32List((cellCount + 1) * 2);
      _nextSlotOfCell = Int32List((cellCount + 1) * 2);
    }
  }

  /// Works out each particle's cell and leaves [cellStarts] holding where
  /// each cell's particles start.
  void _countParticlesPerCell(
    int count,
    int cellCount,
    Float64List positionX,
    Float64List positionY,
    Float64List radius,
  ) {
    final cellOfParticle = _cellOfParticle;
    final cellStarts = this.cellStarts..fillRange(0, cellCount + 1, 0);
    final largestFiledRadius = cellSize / 2;
    largeCount = 0;
    for (var i = 0; i < count; i++) {
      final x = positionX[i], y = positionY[i];
      if (!x.isFinite || !y.isFinite) {
        cellOfParticle[i] = _nowhere;
        continue;
      }
      if (radius[i] > largestFiledRadius) {
        cellOfParticle[i] = _tooLarge;
        largeParticles[largeCount++] = i;
        continue;
      }
      final cell =
          ((y - _top) * _cellsPerPixel).toInt() * columns +
          ((x - _left) * _cellsPerPixel).toInt();
      cellOfParticle[i] = cell;
      // Counted one slot up, so the running total below turns each count
      // into where that cell starts.
      cellStarts[cell + 1]++;
    }
    var filedSoFar = 0;
    for (var cell = 0; cell <= cellCount; cell++) {
      filedSoFar += cellStarts[cell];
      cellStarts[cell] = filedSoFar;
    }
  }

  /// Writes every filed particle into its cell's stretch of
  /// [filedParticles].
  void _placeParticles(int count, int cellCount) {
    final cellOfParticle = _cellOfParticle;
    final nextSlotOfCell = _nextSlotOfCell..setRange(0, cellCount, cellStarts);
    final filedParticles = this.filedParticles;
    for (var i = 0; i < count; i++) {
      final cell = cellOfParticle[i];
      if (cell < 0) continue;
      filedParticles[nextSlotOfCell[cell]++] = i;
    }
  }
}
