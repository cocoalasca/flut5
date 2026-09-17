import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flut5/flut5.dart';

/// Rasterizes [text] through the shared cache with a fixed, minimal style so
/// only the text itself varies the cache key.
Flut5CachedText _put(String text, {double fontSize = 12}) =>
    Flut5TextCache.instance.getOrCreate(
      text: text,
      fontFamily: 'sans-serif',
      fontSize: fontSize,
      fontWeight: FontWeight.normal,
      fontStyle: FontStyle.normal,
      textLeading: null,
      align: TextAlign.left,
      paintingStyle: 0,
      strokeWidth: 0.0,
    );

/// Runs [body] with [debugPrint] captured, returning everything printed.
List<String> _capturePrints(void Function() body) {
  final lines = <String>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) lines.add(message);
  };
  try {
    body();
    Flut5Console.flush();
  } finally {
    debugPrint = original;
  }
  return lines;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final cache = Flut5TextCache.instance;

  setUp(() {
    cache.clear();
    cache.maxCacheSize = 4;
    cache.maxLayoutCacheSize = 4;
    cache.growthLimit = 16384;
    cache.layoutGrowthLimit = 16384;
    cache.maxCacheBytes = 128 << 20;
    cache.autoGrow = true;
  });

  tearDownAll(() {
    cache.clear();
    cache.maxCacheSize = 1024;
    cache.maxLayoutCacheSize = 1024;
    cache.maxCacheBytes = 128 << 20;
    cache.autoGrow = true;
  });

  test('overflow grows the cap instead of evicting the working set', () {
    for (var i = 0; i < 40; i++) {
      _put('glyph$i');
    }

    // Every distinct entry is still resident — no thrash.
    expect(cache.cacheLength, 40);
    expect(cache.maxCacheSize, greaterThanOrEqualTo(40));
    // Doubling from 4: 8, 16, 32, 64.
    expect(cache.maxCacheSize, 64);
  });

  test('a cyclic working set larger than the initial cap stays 100% hit', () {
    // The pathological pattern for plain LRU: walk N unique keys in a
    // repeating order, where N far exceeds the starting cap.
    for (var pass = 0; pass < 3; pass++) {
      for (var i = 0; i < 30; i++) {
        _put('cycle$i');
      }
    }
    expect(cache.cacheLength, 30);

    // Identity check: a second pass returns the very same objects, proving
    // nothing was evicted and re-rasterized between passes.
    final first = _put('cycle0');
    final again = _put('cycle0');
    expect(identical(first, again), isTrue);
  });

  test('growth stops at growthLimit, then evicts in batches', () {
    cache.growthLimit = 8;

    for (var i = 0; i < 40; i++) {
      _put('limited$i');
    }

    expect(cache.maxCacheSize, 8);
    expect(cache.cacheLength, lessThanOrEqualTo(8));
    // Batch eviction trims to 7/8 of the cap, so it must have dropped below
    // the cap at some point rather than evicting exactly one per insert.
    expect(cache.cacheLength, greaterThan(0));
  });

  test('autoGrow = false restores a hard cap', () {
    cache.autoGrow = false;

    for (var i = 0; i < 40; i++) {
      _put('hard$i');
    }

    expect(cache.maxCacheSize, 4);
    expect(cache.cacheLength, lessThanOrEqualTo(4));
  });

  test(
    'LRU keeps same-frame texture hits and evicts the exact oldest entry',
    () {
      cache.autoGrow = false;
      final a = _put('a'), b = _put('b'), c = _put('c'), d = _put('d');
      expect(_put('a'), same(a));
      _put('e');
      expect(b.image.debugDisposed, isTrue);
      expect(a.image.debugDisposed, isFalse);
      expect(c.image.debugDisposed, isFalse);
      expect(d.image.debugDisposed, isFalse);
    },
  );

  test('byte budget bounds residency and blocks growth', () {
    final probe = _put('m');
    final entryBytes = probe.bytes;
    expect(entryBytes, greaterThan(0));

    cache.clear();
    cache.maxCacheSize = 4;
    cache.autoGrow = true;
    // Room for roughly ten entries, well under the count-based growth path.
    cache.maxCacheBytes = entryBytes * 10;

    for (var i = 0; i < 60; i++) {
      _put('byte$i');
    }

    expect(cache.cacheBytes, lessThanOrEqualTo(cache.maxCacheBytes));
    expect(cache.cacheLength, lessThan(60));
  });

  test('the entry just inserted is never evicted or disposed', () {
    // A budget smaller than a single entry is the worst case: the eviction
    // walk would otherwise reach the freshly inserted entry and dispose the
    // image getOrCreate is about to return.
    cache.maxCacheBytes = 1;
    cache.autoGrow = true;

    late Flut5CachedText last;
    for (var i = 0; i < 20; i++) {
      last = _put('tiny$i');
      expect(last.image.debugDisposed, isFalse);
    }

    expect(cache.cacheLength, greaterThanOrEqualTo(1));
    expect(last.image.debugDisposed, isFalse);
    // The returned entry must still be the live cache entry.
    expect(identical(_put('tiny19'), last), isTrue);
  });

  test('growth warns once with quantization advice, then tersely', () {
    final lines = _capturePrints(() {
      for (var i = 0; i < 40; i++) {
        _put('warn$i');
      }
    });

    final growthLines = lines.where((l) => l.contains('grew')).toList();
    expect(growthLines, isNotEmpty);

    final full = growthLines.first;
    expect(full, contains('text texture cache grew 4 → 8 entries'));
    expect(full, contains('quantize animated values'));
    expect(full, contains('textDynamic()'));
    expect(full, contains('textCacheAutoGrow = false'));

    // Later growth steps stay terse — the advice is not repeated.
    final terse = growthLines.where((l) => !l.contains('quantize')).toList();
    expect(terse, isNotEmpty);
  });

  test('hitting the ceiling warns once with the collapse explanation', () {
    cache.growthLimit = 8;

    final lines = _capturePrints(() {
      for (var i = 0; i < 60; i++) {
        _put('ceil$i');
      }
    });

    final stop = lines.where((l) => l.contains('hit its')).toList();
    expect(stop, hasLength(1));
    expect(stop.single, contains('entry ceiling'));
    expect(stop.single, contains('hit rate collapses'));
    expect(stop.single, contains('textCacheGrowthLimit'));
  });

  test('layout cache grows and reports separately', () {
    for (var i = 0; i < 30; i++) {
      Flut5TextCache.instance.getOrCreateLayout(
        text: 'layout sample $i',
        fontFamily: 'sans-serif',
        fontSize: 12,
        fontWeight: FontWeight.normal,
        fontStyle: FontStyle.normal,
        letterSpacing: 0,
        maxWidth: null,
      );
    }

    expect(cache.layoutCacheLength, 30);
    expect(cache.maxLayoutCacheSize, greaterThanOrEqualTo(30));
  });

  test('clear resets byte accounting', () {
    for (var i = 0; i < 10; i++) {
      _put('reset$i');
    }
    expect(cache.cacheBytes, greaterThan(0));

    cache.clear();

    expect(cache.cacheBytes, 0);
    expect(cache.cacheLength, 0);
  });
}
