import 'dart:math';

import 'package:flut5/text/flut5_expiring_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('priority eviction exactly matches sorted LRU victims', () {
    final random = Random(54);
    for (final size in [1, 2, 3, 17, 128, 1024]) {
      final order = List.generate(size, (i) => i)..shuffle(random);
      final map = Flut5ExpiringCache<int, int>(() => 0);
      for (var i = 0; i < size; i++) {
        map[i] = order[i];
      }
      final victims = <int>[];
      final target = size ~/ 2;
      map.evictWhile(
        () => map.length > target,
        (a, b) => a.compareTo(b),
        victims.add,
      );
      expect(victims, List.generate(size - target, (i) => i));
      expect(map.length, target);
    }
  });

  test('priority eviction does not refresh timeout ages or double-dispose', () {
    var frame = 0;
    final disposed = <int>[];
    final map = Flut5ExpiringCache<String, int>(
      () => frame,
      onExpire: disposed.add,
    );
    map['a'] = 3;
    map['b'] = 1;
    map['c'] = 2;
    frame = 2;
    expect(map['a'], 3);
    map.evictWhile(
      () => map.length > 2,
      (a, b) => a.compareTo(b),
      disposed.add,
    );
    expect(disposed, [1]);
    frame = 3;
    map.expire(3);
    expect(disposed, [1, 2]);
    frame = 5;
    map.expire(3);
    expect(disposed, [1, 2, 3]);
  });

  test('false eviction predicate leaves every entry untouched', () {
    final map = Flut5ExpiringCache<int, int>(() => 0)..[1] = 10;
    map.evictWhile(
      () => false,
      (_, _) => throw StateError('unneeded comparison'),
      (_) => fail('unexpected removal'),
    );
    expect(map[1], 10);
  });
}
