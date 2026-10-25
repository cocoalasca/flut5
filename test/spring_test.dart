import 'package:flutter_test/flutter_test.dart';
import 'package:flut5/flut5.dart';

void main() {
  group('Flut5Spring', () {
    test('springConstant defaults to 0.1 and get-or-sets', () {
      final e = Flut5Engine();
      expect(e.springConstant(), 0.1);
      expect(e.springConstant(0.5), 0.5);
      expect(e.springConstant(), 0.5);
    });

    test('springConstant rejects negative k', () {
      final e = Flut5Engine();
      expect(() => e.springConstant(-1), throwsArgumentError);
      expect(e.springConstant(), 0.1);
    });

    test('springForce pulls position back toward rest', () {
      final e = Flut5Engine()..springConstant(0.5);
      final position = Flut5Vector(110, 80);
      final rest = Flut5Vector(100, 100);
      final f = e.springForce(position, rest);
      expect(f.x, -5.0);
      expect(f.y, 10.0);
      // Inputs untouched.
      expect(position.x, 110.0);
      expect(rest.y, 100.0);
    });

    test('springForce is zero at rest', () {
      final e = Flut5Engine();
      final f = e.springForce(Flut5Vector(3, 4), Flut5Vector(3, 4));
      expect(f.length, 0.0);
    });
  });
}
