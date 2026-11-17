import 'package:flutter_test/flutter_test.dart';
import 'package:flut5/flut5.dart';

void main() {
  late Flut5Engine engine;

  setUp(() => engine = Flut5Engine());

  group('seek', () {
    test('generates a force toward the target, capped at maxForce', () {
      final force = engine.seek(
        Flut5Vector(0, 0),
        Flut5Vector.zero(),
        Flut5Vector(100, 0),
      );

      expect(force.x, greaterThan(0.0));
      expect(force.y, 0.0);
      expect(force.mag(), closeTo(0.1, 1e-12));
    });

    test('uses the limits passed in', () {
      final force = engine.seek(
        Flut5Vector(0, 0),
        Flut5Vector.zero(),
        Flut5Vector(100, 0),
        maxVelocity: 3.0,
        maxForce: 10.0,
      );

      // maxForce is above maxVelocity, so the force is the full desired
      // velocity.
      expect(force.x, closeTo(3.0, 1e-12));
      expect(force.y, 0.0);
    });

    test('subtracts the current velocity', () {
      final force = engine.seek(
        Flut5Vector(3, 5),
        Flut5Vector(1, -2),
        Flut5Vector(37, -19),
        maxForce: 100.0,
      );

      final expected = Flut5Vector(
        37,
        -19,
      ).sub(Flut5Vector(3, 5)).setMag(4.0).sub(Flut5Vector(1, -2));
      expect(force.x, closeTo(expected.x, 1e-12));
      expect(force.y, closeTo(expected.y, 1e-12));
    });

    test('does not modify its arguments', () {
      final position = Flut5Vector(3, 5);
      final velocity = Flut5Vector(1, -2);
      final target = Flut5Vector(37, -19);

      engine.seek(position, velocity, target);

      expect([position.x, position.y], [3.0, 5.0]);
      expect([velocity.x, velocity.y], [1.0, -2.0]);
      expect([target.x, target.y], [37.0, -19.0]);
    });
  });

  group('arrive', () {
    test('slows down within slowingRadius', () {
      final far = engine.arrive(
        Flut5Vector(0, 0),
        Flut5Vector.zero(),
        Flut5Vector(200, 0), // outside the default 100 slowingRadius
        maxForce: 10.0,
        returnCopy: true,
      );
      final near = engine.arrive(
        Flut5Vector(0, 0),
        Flut5Vector.zero(),
        Flut5Vector(50, 0), // inside the default 100 slowingRadius
        maxForce: 10.0,
        returnCopy: true,
      );

      expect(far.x, closeTo(4.0, 1e-12));
      expect(near.x, closeTo(2.0, 1e-12)); // 50 / 100 * maxVelocity
    });

    test('honours a custom slowingRadius', () {
      final force = engine.arrive(
        Flut5Vector(0, 0),
        Flut5Vector.zero(),
        Flut5Vector(50, 0),
        slowingRadius: 200.0,
        maxVelocity: 8.0,
        maxForce: 10.0,
      );

      expect(force.x, closeTo(2.0, 1e-12)); // 50 / 200 * 8
    });
  });

  group('flee', () {
    test('generates a force away from a target within the radius', () {
      final force = engine.flee(
        Flut5Vector(0, 0),
        Flut5Vector.zero(),
        Flut5Vector(20, 0),
        fleeRadius: 50.0,
      );

      expect(force.x, lessThan(0.0));
      expect(force.y, 0.0);
    });

    test('ignores targets outside the radius', () {
      final force = engine.flee(
        Flut5Vector(0, 0),
        Flut5Vector.zero(),
        Flut5Vector(100, 0),
        fleeRadius: 50.0,
      );

      expect([force.x, force.y, force.z], [0.0, 0.0, 0.0]);
    });

    test('with no radius always applies a force', () {
      final force = engine.flee(
        Flut5Vector(0, 0),
        Flut5Vector.zero(),
        Flut5Vector(1000, 0),
      );

      expect(force.x, lessThan(0.0));
      expect(force.y, 0.0);
    });

    test('reverses the desired velocity, not the whole steering force', () {
      final force = engine.flee(
        Flut5Vector(3, 5),
        Flut5Vector(1, -2),
        Flut5Vector(37, -19),
      );

      // desired = setMag(position - target, maxVelocity); steer = desired - velocity
      final expected = Flut5Vector(3, 5)
          .sub(Flut5Vector(37, -19))
          .setMag(4.0)
          .sub(Flut5Vector(1, -2))
          .limit(0.1);

      expect(force.x, closeTo(expected.x, 1e-12));
      expect(force.y, closeTo(expected.y, 1e-12));
      expect(force.z, closeTo(expected.z, 1e-12));
    });

    test('still steers away when charging the target at max speed', () {
      // Moving straight at the target at full speed — the case where negating
      // seek would have produced zero force.
      final force = engine.flee(
        Flut5Vector(0, 0),
        Flut5Vector(4.0, 0),
        Flut5Vector(20, 0),
      );

      expect(force.x, closeTo(-0.1, 1e-12));
      expect(force.y, closeTo(0.0, 1e-12));
    });
  });

  group('separation', () {
    test('pushes away from a close neighbor, capped at maxForce', () {
      final force = engine.separation(Flut5Vector(0, 0), Flut5Vector.zero(), [
        Flut5Vector(10, 0),
      ], separationRadius: 50.0);

      expect(force.x, closeTo(-0.1, 1e-12));
      expect(force.y, 0.0);
    });

    test('matches the reference flocking formula', () {
      final position = Flut5Vector(3, 5);
      final velocity = Flut5Vector(1, -2);
      final neighbors = [Flut5Vector(13, 5), Flut5Vector(3, -25)];

      final force = engine.separation(
        position,
        velocity,
        neighbors,
        maxForce: 100.0,
      );

      // Sum of (position - neighbor) / distance², set to maxVelocity, minus
      // velocity.
      final expected = Flut5Vector.zero();
      for (final neighbor in neighbors) {
        final away = position.copy().sub(neighbor);
        expected.add(away.copy().div(away.length2));
      }
      expected
        ..setMag(4.0)
        ..sub(velocity);

      expect(force.x, closeTo(expected.x, 1e-12));
      expect(force.y, closeTo(expected.y, 1e-12));
      // The closer neighbor (10 px to the right) dominates the farther one
      // (30 px below), so the push is mostly to the left.
      expect(force.x.abs(), greaterThan(force.y.abs()));
    });

    test('ignores neighbors outside separationRadius', () {
      final force = engine.separation(Flut5Vector(0, 0), Flut5Vector(1, 1), [
        Flut5Vector(100, 0),
        Flut5Vector(0, 60),
      ], separationRadius: 50.0);

      expect([force.x, force.y, force.z], [0.0, 0.0, 0.0]);
    });

    test('with no radius every neighbor counts', () {
      final force = engine.separation(Flut5Vector(0, 0), Flut5Vector.zero(), [
        Flut5Vector(1000, 0),
      ]);

      expect(force.x, lessThan(0.0));
    });

    test('skips its own position in the neighbor list', () {
      final position = Flut5Vector(0, 0);

      final alone = engine.separation(position, Flut5Vector.zero(), [position]);
      expect([alone.x, alone.y, alone.z], [0.0, 0.0, 0.0]);

      final withOther = engine.separation(position, Flut5Vector.zero(), [
        position,
        Flut5Vector(0, 10),
      ]);
      expect(withOther.x, 0.0);
      expect(withOther.y, closeTo(-0.1, 1e-12));
    });

    test('brakes when the pushes cancel out', () {
      final force = engine.separation(Flut5Vector(0, 0), Flut5Vector(1, 0), [
        Flut5Vector(10, 0),
        Flut5Vector(-10, 0),
      ], maxForce: 100.0);

      expect(force.x, closeTo(-1.0, 1e-12));
      expect(force.y, 0.0);
    });

    test('does not modify its arguments', () {
      final position = Flut5Vector(3, 5);
      final velocity = Flut5Vector(1, -2);
      final neighbor = Flut5Vector(8, 5);

      engine.separation(position, velocity, [neighbor]);

      expect([position.x, position.y], [3.0, 5.0]);
      expect([velocity.x, velocity.y], [1.0, -2.0]);
      expect([neighbor.x, neighbor.y], [8.0, 5.0]);
    });

    test('follows the steering return mode', () {
      engine.steeringTurboMode(true);
      final shared = engine.seek(
        Flut5Vector(0, 0),
        Flut5Vector.zero(),
        Flut5Vector(100, 0),
      );
      final separated = engine.separation(
        Flut5Vector(0, 0),
        Flut5Vector.zero(),
        [Flut5Vector(10, 0)],
      );

      expect(identical(shared, separated), isTrue);
    });
  });

  group('cohesion', () {
    test('steers toward the center of the neighbors', () {
      final force = engine.cohesion(Flut5Vector(0, 0), Flut5Vector.zero(), [
        Flut5Vector(10, 10),
        Flut5Vector(30, -10),
      ], maxForce: 100.0);

      // Center (20, 0), straight to the right at maxVelocity.
      expect(force.x, closeTo(4.0, 1e-12));
      expect(force.y, closeTo(0.0, 1e-12));
    });

    test('is seek toward the center', () {
      final position = Flut5Vector(3, 5);
      final velocity = Flut5Vector(1, -2);
      final neighbors = [
        Flut5Vector(13, 5),
        Flut5Vector(3, -25),
        Flut5Vector(-7, 11),
      ];

      final force = engine.cohesion(position, velocity, neighbors);
      final center = Flut5Vector(13 + 3 - 7, 5 - 25 + 11).div(3);
      final expected = engine.seek(position, velocity, center);

      expect(force.x, closeTo(expected.x, 1e-12));
      expect(force.y, closeTo(expected.y, 1e-12));
      expect(force.z, closeTo(expected.z, 1e-12));
    });

    test('ignores neighbors outside cohesionRadius', () {
      final force = engine.cohesion(Flut5Vector(0, 0), Flut5Vector.zero(), [
        Flut5Vector(0, 20),
        Flut5Vector(500, 0),
      ], cohesionRadius: 50.0);

      // Only the neighbor below counts, so the pull is straight down.
      expect(force.x, 0.0);
      expect(force.y, closeTo(0.1, 1e-12));
    });

    test('returns zero when no neighbor is in range', () {
      final force = engine.cohesion(Flut5Vector(0, 0), Flut5Vector(1, 1), [
        Flut5Vector(500, 0),
      ], cohesionRadius: 50.0);

      expect([force.x, force.y, force.z], [0.0, 0.0, 0.0]);
    });

    test('skips its own position in the neighbor list', () {
      final position = Flut5Vector(0, 0);

      final alone = engine.cohesion(position, Flut5Vector.zero(), [position]);
      expect([alone.x, alone.y, alone.z], [0.0, 0.0, 0.0]);

      final withOthers = engine.cohesion(position, Flut5Vector.zero(), [
        position,
        Flut5Vector(20, 0),
        Flut5Vector(40, 0),
      ], maxForce: 100.0);
      expect(withOthers.x, closeTo(4.0, 1e-12));
      expect(withOthers.y, 0.0);
    });

    test('brakes when already on the center', () {
      final force = engine.cohesion(Flut5Vector(0, 0), Flut5Vector(1, 0), [
        Flut5Vector(10, 0),
        Flut5Vector(-10, 0),
      ], maxForce: 100.0);

      expect(force.x, closeTo(-1.0, 1e-12));
      expect(force.y, 0.0);
    });

    test('does not modify its arguments', () {
      final position = Flut5Vector(3, 5);
      final velocity = Flut5Vector(1, -2);
      final neighbor = Flut5Vector(8, 5);

      engine.cohesion(position, velocity, [neighbor]);

      expect([position.x, position.y], [3.0, 5.0]);
      expect([velocity.x, velocity.y], [1.0, -2.0]);
      expect([neighbor.x, neighbor.y], [8.0, 5.0]);
    });

    test('follows the steering return mode', () {
      engine.steeringTurboMode(true);
      final shared = engine.seek(
        Flut5Vector(0, 0),
        Flut5Vector.zero(),
        Flut5Vector(100, 0),
      );
      final pulled = engine.cohesion(Flut5Vector(0, 0), Flut5Vector.zero(), [
        Flut5Vector(10, 0),
      ]);

      expect(identical(shared, pulled), isTrue);
    });
  });

  group('return mode', () {
    final position = Flut5Vector(0, 0);
    final velocity = Flut5Vector.zero();
    final target = Flut5Vector(100, 0);

    test('copy mode (default) returns a new vector each call', () {
      final first = engine.seek(position, velocity, target);
      final second = engine.seek(position, velocity, target);

      expect(identical(first, second), isFalse);
    });

    test('turbo mode returns the same shared vector each call', () {
      engine.steeringTurboMode(true);
      final first = engine.seek(position, velocity, target);
      final second = engine.flee(position, velocity, target);

      expect(identical(first, second), isTrue);
    });

    test('returnCopy overrides the mode for one call', () {
      engine.steeringTurboMode(true);
      final shared = engine.seek(position, velocity, target);
      final copied = engine.seek(position, velocity, target, returnCopy: true);

      expect(identical(shared, copied), isFalse);
    });

    test('resetSteeringMode goes back to copies', () {
      engine.steeringReturnMode(SteeringReturnMode.ref);
      engine.resetSteeringMode();
      final first = engine.seek(position, velocity, target);
      final second = engine.seek(position, velocity, target);

      expect(identical(first, second), isFalse);
    });

    test('the mode belongs to the engine, not the process', () {
      engine.steeringTurboMode(true);
      final other = Flut5Engine();
      final first = other.seek(position, velocity, target);
      final second = other.seek(position, velocity, target);

      expect(identical(first, second), isFalse);
    });
  });
}
