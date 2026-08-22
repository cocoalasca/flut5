import 'dart:math' as math;
import 'dart:typed_data';

/// The noise algorithm used by [Flut5Noise.noise].
enum NoiseMode {
  /// Gradient-based simplex noise.
  ///
  /// Returns values in `[-1, 1]`. Faster at higher dimensions, with fewer
  /// directional artefacts than [perlin].
  simplex,

  /// Value noise ported from p5.js.
  ///
  /// Returns values in `[0, 1]`. Uses cosine interpolation and looks smooth
  /// and organic.
  perlin,
}

/// Provides noise generation to the Flut5 Engine.
///
/// Two algorithms are available, selected via [noiseMode]:
///
/// * **[NoiseMode.simplex]** (default) — gradient-based simplex noise
///   returning values in `[-1, 1]`.
/// * **[NoiseMode.perlin]** — p5.js-style value noise returning values
///   in `[0, 1]`.
///
/// API:
/// * [noise]        — returns a noise value (range depends on active mode).
/// * [noiseDetail]  — adjusts octaves and amplitude falloff for the active mode.
/// * [noiseSeed]    — seeds the active mode for reproducible results.
/// * [resetNoise]   — clears the active mode's lookup / permutation table.
/// * [noiseMode]    — switches between [NoiseMode.simplex] and [NoiseMode.perlin].
base mixin Flut5Noise {
  // ═══════════════════════════════════════════════════════════════════════
  // ── Mode ──────────────────────────────────────────────────────────────
  // ═══════════════════════════════════════════════════════════════════════

  NoiseMode _currentNoiseMode = .simplex;

  /// The active noise algorithm.
  NoiseMode get noiseMode => _currentNoiseMode;

  /// Switches the noise algorithm.
  ///
  /// The active mode determines which algorithm [noise], [noiseDetail],
  /// [noiseSeed], and [resetNoise] operate on.
  set noiseMode(NoiseMode mode) => _currentNoiseMode = mode;

  // ═══════════════════════════════════════════════════════════════════════
  // ── Unified public API ────────────────────────────────────────────────
  // ═══════════════════════════════════════════════════════════════════════

  /// Returns a noise value for the given coordinates.
  ///
  /// The output range depends on the active [noiseMode]:
  /// * [NoiseMode.simplex] → `[-1, 1]`
  /// * [NoiseMode.perlin]  → `[0, 1]`
  ///
  /// Supports 1-D (`noise(x)`), 2-D (`noise(x, y)`), and 3-D
  /// (`noise(x, y, z)`).
  double noise(double x, [double y = 0.0, double z = 0.0]) {
    return switch (_currentNoiseMode) {
      .simplex => _simplexNoise(x, y, z),
      .perlin  => _perlinNoise(x, y, z),
    };
  }

  /// Adjusts the character of the noise produced by [noise].
  ///
  /// [lod] (level of detail) sets the number of octaves.
  /// [falloff] controls how much each successive octave contributes (0 – 1).
  ///
  /// Applies to the currently active [noiseMode].
  void noiseDetail(int lod, [double? falloff]) {
    switch (_currentNoiseMode) {
      case .simplex:
        if (lod > 0) _simplexOctaves = lod;
        if (falloff != null && falloff > 0) _simplexAmpFalloff = falloff;
      case .perlin:
        if (lod > 0) _perlinOctaves = lod;
        if (falloff != null && falloff > 0) _perlinAmpFalloff = falloff;
    }
  }

  /// Seeds the noise generator for reproducible results.
  ///
  /// Applies to the currently active [noiseMode].
  void noiseSeed(int seed) {
    switch (_currentNoiseMode) {
      case .simplex:
        _seedSimplex(seed);
      case .perlin:
        _seedPerlin(seed);
    }
  }

  /// Resets the noise state so the next call to [noise] generates a fresh
  /// sequence.
  ///
  /// Applies to the currently active [noiseMode].
  void resetNoise() {
    switch (_currentNoiseMode) {
      case .simplex:
        _simplexPerm = null;
      case .perlin:
        _perlin = null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // ── Perlin value noise (p5.js port) ───────────────────────────────────
  // ═══════════════════════════════════════════════════════════════════════

  static const int _perlinYWrapB = 4;
  static const int _perlinYWrap = 1 << _perlinYWrapB; // 16
  static const int _perlinZWrapB = 8;
  static const int _perlinZWrap = 1 << _perlinZWrapB; // 256
  static const int _perlinSize = 4095;

  int _perlinOctaves = 4;
  double _perlinAmpFalloff = 0.5;
  Float64List? _perlin;

  static double _scaledCosine(double i) =>
      0.5 * (1.0 - math.cos(i * math.pi));

  static Float64List _initPerlin([math.Random? rng]) {
    rng ??= math.Random();
    final p = Float64List(_perlinSize + 1);
    for (int i = 0; i <= _perlinSize; i++) {
      p[i] = rng.nextDouble();
    }
    return p;
  }

  void _seedPerlin(int seed) {
    _perlin = _initPerlin(math.Random(seed));
  }

  /// Returns `[0, 1]` value noise (p5.js algorithm).
  double _perlinNoise(double x, double y, double z) {
    _perlin ??= _initPerlin();

    final p = _perlin!;

    if (x < 0) x = -x;
    if (y < 0) y = -y;
    if (z < 0) z = -z;

    int xi = x.floor();
    int yi = y.floor();
    int zi = z.floor();

    double xf = x - xi;
    double yf = y - yi;
    double zf = z - zi;

    double r = 0;
    double ampl = 0.5;

    for (int o = 0; o < _perlinOctaves; o++) {
      int of_ = xi + (yi << _perlinYWrapB) + (zi << _perlinZWrapB);

      final rxf = _scaledCosine(xf);
      final ryf = _scaledCosine(yf);

      double n1 = p[of_ & _perlinSize];
      n1 += rxf * (p[(of_ + 1) & _perlinSize] - n1);

      double n2 = p[(of_ + _perlinYWrap) & _perlinSize];
      n2 += rxf * (p[(of_ + _perlinYWrap + 1) & _perlinSize] - n2);

      n1 += ryf * (n2 - n1);

      of_ += _perlinZWrap;

      n2 = p[of_ & _perlinSize];
      n2 += rxf * (p[(of_ + 1) & _perlinSize] - n2);

      double n3 = p[(of_ + _perlinYWrap) & _perlinSize];
      n3 += rxf * (p[(of_ + _perlinYWrap + 1) & _perlinSize] - n3);

      n2 += ryf * (n3 - n2);

      n1 += _scaledCosine(zf) * (n2 - n1);

      r += n1 * ampl;
      ampl *= _perlinAmpFalloff;

      xi <<= 1;
      xf *= 2;
      yi <<= 1;
      yf *= 2;
      zi <<= 1;
      zf *= 2;

      if (xf >= 1.0) { xi++; xf -= 1.0; }
      if (yf >= 1.0) { yi++; yf -= 1.0; }
      if (zf >= 1.0) { zi++; zf -= 1.0; }
    }

    return r;
  }

  // ═══════════════════════════════════════════════════════════════════════
  // ── Simplex noise ─────────────────────────────────────────────────────
  // ═══════════════════════════════════════════════════════════════════════

  // ── Skew / unskew factors (3-D) ───────────────────────────────────────
  static const double _f3 = 1.0 / 3.0;
  static const double _g3 = 1.0 / 6.0;

  /// 3-D gradient vectors (12 directions), stored flat for cache locality.
  static final Float64List _grad3 = Float64List.fromList([
    // x,  y,  z
     1,  1,  0,  -1,  1,  0,   1, -1,  0,  -1, -1,  0,
     1,  0,  1,  -1,  0,  1,   1,  0, -1,  -1,  0, -1,
     0,  1,  1,   0, -1,  1,   0,  1, -1,   0, -1, -1,
  ]);

  /// Classic permutation table (0–255).
  static const List<int> _defaultPerm = [
    151,160,137, 91, 90, 15,131, 13,201, 95, 96, 53,194,233,  7,225,
    140, 36,103, 30, 69,142,  8, 99, 37,240, 21, 10, 23,190,  6,148,
    247,120,234, 75,  0, 26,197, 62, 94,252,219,203,117, 35, 11, 32,
     57,177, 33, 88,237,149, 56, 87,174, 20,125,136,171,168, 68,175,
     74,165, 71,134,139, 48, 27,166, 77,146,158,231, 83,111,229,122,
     60,211,133,230,220,105, 92, 41, 55, 46,245, 40,244,102,143, 54,
     65, 25, 63,161,  1,216, 80, 73,209, 76,132,187,208, 89, 18,169,
    200,196,135,130,116,188,159, 86,164,100,109,198,173,186,  3, 64,
     52,217,226,250,124,123,  5,202, 38,147,118,126,255, 82, 85,212,
    207,206, 59,227, 47, 16, 58, 17,182,189, 28, 42,223,183,170,213,
    119,248,152,  2, 44,154,163, 70,221,153,101,155,167, 43,172,  9,
    129, 22, 39,253, 19, 98,108,110, 79,113,224,232,178,185,112,104,
    218,246, 97,228,251, 34,242,193,238,210,144, 12,191,179,162,241,
     81, 51,145,235,249, 14,239,107, 49,192,214, 31,181,199,106,157,
    184, 84,204,176,115,121, 50, 45,127,  4,150,254,138,236,205, 93,
    222,114, 67, 29, 24, 72,243,141,128,195, 78, 66,215, 61,156,180,
  ];

  int _simplexOctaves = 4;
  double _simplexAmpFalloff = 0.5;
  Int32List? _simplexPerm;

  static Int32List _buildPerm(List<int> source) {
    final perm = Int32List(512);
    for (int i = 0; i < 512; i++) {
      perm[i] = source[i & 255];
    }
    return perm;
  }

  void _seedSimplex(int seed) {
    final rng = math.Random(seed);
    final source = List<int>.generate(256, (i) => i);
    for (int i = 255; i > 0; i--) {
      final j = rng.nextInt(i + 1);
      final tmp = source[i];
      source[i] = source[j];
      source[j] = tmp;
    }
    _simplexPerm = _buildPerm(source);
  }

  /// Returns `[-1, 1]` simplex noise with fBm octaves.
  double _simplexNoise(double x, double y, double z) {
    _simplexPerm ??= _buildPerm(_defaultPerm);
    final perm = _simplexPerm!;

    double r = 0.0;
    double amp = 1.0;
    double freq = 1.0;
    double maxAmp = 0.0;

    for (int o = 0; o < _simplexOctaves; o++) {
      final raw = _rawSimplex3(x * freq, y * freq, z * freq, perm);
      r += raw * amp;
      maxAmp += amp;
      amp *= _simplexAmpFalloff;
      freq *= 2.0;
    }

    // Normalize to [-1, 1].
    r /= maxAmp;
    return r;
  }

  // ── Raw 3-D simplex noise (returns ≈ [-1, 1]) ────────────────────────
  static double _rawSimplex3(
    double x,
    double y,
    double z,
    Int32List perm,
  ) {
    final s = (x + y + z) * _f3;
    final i = (x + s).floor();
    final j = (y + s).floor();
    final k = (z + s).floor();

    final t = (i + j + k) * _g3;
    final x0 = x - (i - t);
    final y0 = y - (j - t);
    final z0 = z - (k - t);

    int i1, j1, k1;
    int i2, j2, k2;

    if (x0 >= y0) {
      if (y0 >= z0) {
        i1 = 1; j1 = 0; k1 = 0; i2 = 1; j2 = 1; k2 = 0;
      } else if (x0 >= z0) {
        i1 = 1; j1 = 0; k1 = 0; i2 = 1; j2 = 0; k2 = 1;
      } else {
        i1 = 0; j1 = 0; k1 = 1; i2 = 1; j2 = 0; k2 = 1;
      }
    } else {
      if (y0 < z0) {
        i1 = 0; j1 = 0; k1 = 1; i2 = 0; j2 = 1; k2 = 1;
      } else if (x0 < z0) {
        i1 = 0; j1 = 1; k1 = 0; i2 = 0; j2 = 1; k2 = 1;
      } else {
        i1 = 0; j1 = 1; k1 = 0; i2 = 1; j2 = 1; k2 = 0;
      }
    }

    final x1 = x0 - i1 + _g3;
    final y1 = y0 - j1 + _g3;
    final z1 = z0 - k1 + _g3;
    final x2 = x0 - i2 + 2.0 * _g3;
    final y2 = y0 - j2 + 2.0 * _g3;
    final z2 = z0 - k2 + 2.0 * _g3;
    final x3 = x0 - 1.0 + 3.0 * _g3;
    final y3 = y0 - 1.0 + 3.0 * _g3;
    final z3 = z0 - 1.0 + 3.0 * _g3;

    final ii = i & 255;
    final jj = j & 255;
    final kk = k & 255;

    double n0, n1, n2, n3;

    double t0 = 0.6 - x0 * x0 - y0 * y0 - z0 * z0;
    if (t0 < 0) {
      n0 = 0.0;
    } else {
      t0 *= t0;
      final gi0 = (perm[ii + perm[jj + perm[kk]]] % 12) * 3;
      n0 = t0 * t0 * _dot3(gi0, x0, y0, z0);
    }

    double t1 = 0.6 - x1 * x1 - y1 * y1 - z1 * z1;
    if (t1 < 0) {
      n1 = 0.0;
    } else {
      t1 *= t1;
      final gi1 = (perm[ii + i1 + perm[jj + j1 + perm[kk + k1]]] % 12) * 3;
      n1 = t1 * t1 * _dot3(gi1, x1, y1, z1);
    }

    double t2 = 0.6 - x2 * x2 - y2 * y2 - z2 * z2;
    if (t2 < 0) {
      n2 = 0.0;
    } else {
      t2 *= t2;
      final gi2 = (perm[ii + i2 + perm[jj + j2 + perm[kk + k2]]] % 12) * 3;
      n2 = t2 * t2 * _dot3(gi2, x2, y2, z2);
    }

    double t3 = 0.6 - x3 * x3 - y3 * y3 - z3 * z3;
    if (t3 < 0) {
      n3 = 0.0;
    } else {
      t3 *= t3;
      final gi3 = (perm[ii + 1 + perm[jj + 1 + perm[kk + 1]]] % 12) * 3;
      n3 = t3 * t3 * _dot3(gi3, x3, y3, z3);
    }

    return 32.0 * (n0 + n1 + n2 + n3);
  }

  static double _dot3(int gi, double x, double y, double z) =>
      _grad3[gi] * x + _grad3[gi + 1] * y + _grad3[gi + 2] * z;
}
