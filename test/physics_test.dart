import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:flut5/flut5.dart';

/// A stretched horizontal spring: particles 100 apart, resting at 50.
(Flut5Engine, Flut5PhysicsSpring) stretchedSpring({double k = 0.1}) {
  final e = Flut5Engine()..springConstant(k);
  final a = e.physicsEngine.createParticle(0, 0);
  final b = e.physicsEngine.createParticle(100, 0);
  final s = e.physicsEngine.createSpring(a, b)..restLength = 50;
  return (e, s);
}

/// An engine whose window is 200 × 100.
Flut5Engine windowed() =>
    Flut5Engine()
      ..environment = const SketchEnvironment().withSize(const Size(200, 100));

void main() {
  group('Flut5PhysicsParticle', () {
    test('starts at x, y at rest with unit mass', () {
      final p = Flut5PhysicsParticle(10, 20);
      expect(p.x, 10.0);
      expect(p.y, 20.0);
      expect(p.velocity.length, 0.0);
      expect(p.mass, 1.0);
    });

    test('applyForce divides by mass and leaves the force untouched', () {
      final p = Flut5PhysicsParticle(0, 0)..mass = 2;
      final f = Flut5Vector(4, -2);
      p.applyForce(f);
      expect(p.acceleration.x, 2.0);
      expect(p.acceleration.y, -1.0);
      expect(f.x, 4.0);
    });

    test('euler adds gravity, integrates and resets acceleration', () {
      final p = Flut5PhysicsParticle(0, 0);
      p.applyForce(Flut5Vector(1, 0));
      p.euler(Flut5Vector(0, 2));
      expect(p.velocity.x, 1.0);
      expect(p.velocity.y, 2.0);
      expect(p.position.x, 1.0);
      expect(p.position.y, 2.0);
      expect(p.acceleration.length, 0.0);
    });

    test('updatePhysics integrates and clears acceleration', () {
      final p = Flut5PhysicsParticle(0, 0)..damping = 0.5;
      p.applyForce(Flut5Vector(2, 0));
      p.updatePhysics(Flut5PhysicsEngine());
      expect(p.velocity.x, 1.0);
      expect(p.x, 1.0);
      expect(p.acceleration.length, 0.0);
    });
  });

  group('Flut5PhysicsEngine', () {
    test('createPhysicsParticle registers and returns a live reference', () {
      final e = Flut5Engine();
      final p = e.physicsEngine.createParticle(5, 5);
      expect(e.physicsEngine.bodies, [p]);
      p.velocity.x = 3; // local edit
      e.physicsEngine.update(); // global pass sees it
      expect(p.x, 8.0);
    });

    test('particles lists particles; both lists are read-only', () {
      final e = Flut5Engine();
      e.physicsEngine.createParticle(0, 0);
      expect(e.physicsEngine.particles, hasLength(1));
      expect(() => e.physicsEngine.bodies.clear(), throwsUnsupportedError);
      expect(() => e.physicsEngine.particles.clear(), throwsUnsupportedError);
    });

    test('removePhysicsBody stops stepping that body', () {
      final e = Flut5Engine();
      final a = e.physicsEngine.createParticle(0, 0)..velocity.x = 1;
      final b = e.physicsEngine.createParticle(0, 0)..velocity.x = 1;
      expect(e.physicsEngine.remove(a), isTrue);
      e.physicsEngine.update();
      expect(a.x, 0.0);
      expect(b.x, 1.0);
    });

    test('clear empties both lists', () {
      final e = Flut5Engine();
      e.physicsEngine
        ..createParticle(0, 0)
        ..createParticle(1, 1);
      e.physicsEngine.clear();
      expect(e.physicsEngine.bodies, isEmpty);
      expect(e.physicsEngine.particles, isEmpty);
    });

    test('remove drops a particle from particles too', () {
      final e = Flut5Engine();
      final p = e.physicsEngine.createParticle(0, 0);
      e.physicsEngine.remove(p);
      expect(e.physicsEngine.particles, isEmpty);
    });

    test('gravity pulls every particle equally regardless of mass', () {
      final e = Flut5Engine();
      e.physicsEngine.gravity = Flut5Vector(0, 0.5);
      final light = e.physicsEngine.createParticle(0, 0);
      final heavy = e.physicsEngine.createParticle(0, 0)..mass = 10;
      e.physicsEngine.update();
      e.physicsEngine.update();
      expect(light.velocity.y, 1.0);
      expect(light.y, 1.5);
      expect(heavy.y, light.y);
    });

    test('setGravity sets a straight-down vector', () {
      final physics = Flut5Engine().physicsEngine
        ..gravity = Flut5Vector(0.3, 0.1);
      physics.setGravity(0.4);
      expect(physics.gravity.x, 0.0);
      expect(physics.gravity.y, 0.4);
    });

    test('gravity defaults to zero', () {
      expect(Flut5Engine().physicsEngine.gravity.length, 0.0);
    });

    test('timing defaults to beforeDraw', () {
      expect(
        Flut5Engine().physicsEngine.updateTiming,
        PhysicsUpdateTiming.beforeDraw,
      );
    });

    test('spring + particle settle toward rest', () {
      final e = Flut5Engine()..springConstant(0.1);
      final rest = Flut5Vector(100, 100);
      final p = e.physicsEngine.createParticle(150, 100)..damping = 0.9;
      for (var i = 0; i < 300; i++) {
        p.applyForce(e.springForce(p.position, rest));
        e.physicsEngine.update();
      }
      expect(p.x, closeTo(100, 0.01));
    });
  });

  group('Flut5PhysicsSpring', () {
    test('createSpring registers it with rest = initial distance', () {
      final e = Flut5Engine();
      final a = e.physicsEngine.createParticle(0, 0);
      final b = e.physicsEngine.createParticle(30, 40);
      final s = e.physicsEngine.createSpring(a, b);
      expect(s.restLength, 50.0);
      expect(e.physicsEngine.springs, [s]);
      expect(e.physicsEngine.bodies, [a, b, s]);
    });

    test('a spring at rest length exerts no force', () {
      final e = Flut5Engine();
      final a = e.physicsEngine.createParticle(0, 0);
      final b = e.physicsEngine.createParticle(100, 0);
      e.physicsEngine.createSpring(a, b);
      e.physicsEngine.update();
      expect(a.x, 0.0);
      expect(b.x, 100.0);
    });

    test('stretched spring pulls both ends together in the same step', () {
      final (e, s) = stretchedSpring();
      e.physicsEngine.update();
      // k * stretch = 0.1 * 50 = 5, applied before integration.
      expect(s.a.velocity.x, 5.0);
      expect(s.b.velocity.x, -5.0);
      expect(s.a.x, 5.0);
      expect(s.b.x, 95.0);
    });

    test('compressed spring pushes the ends apart', () {
      final (e, s) = stretchedSpring();
      s.restLength = 150;
      e.physicsEngine.update();
      expect(s.a.velocity.x, lessThan(0));
      expect(s.b.velocity.x, greaterThan(0));
    });

    test('heavier particle moves less', () {
      final (e, s) = stretchedSpring();
      s.b.mass = 5;
      e.physicsEngine.update();
      expect(s.a.velocity.x, 5.0);
      expect(s.b.velocity.x, -1.0);
    });

    test('own k overrides the global; null follows it', () {
      final (e, s) = stretchedSpring();
      expect(s.effectiveK(e.physicsEngine), 0.1);
      e.springConstant(0.2);
      expect(s.effectiveK(e.physicsEngine), 0.2);
      s.k = 0.02;
      e.physicsEngine.update();
      expect(s.a.velocity.x, closeTo(1.0, 1e-12));
    });

    test('coincident particles are skipped, not NaN', () {
      final e = Flut5Engine();
      final a = e.physicsEngine.createParticle(10, 10);
      final b = e.physicsEngine.createParticle(10, 10);
      e.physicsEngine.createSpring(a, b).restLength = 5;
      e.physicsEngine.update();
      expect(a.x, 10.0);
      expect(b.y, 10.0);
    });

    test('removing a particle removes its springs', () {
      final (e, s) = stretchedSpring();
      final c = e.physicsEngine.createParticle(0, 50);
      final other = e.physicsEngine.createSpring(s.b, c);
      e.physicsEngine.remove(s.a);
      expect(e.physicsEngine.springs, [other]);
      expect(e.physicsEngine.bodies, isNot(contains(s)));
    });

    test('remove and clear handle springs', () {
      final (e, s) = stretchedSpring();
      expect(e.physicsEngine.remove(s), isTrue);
      expect(e.physicsEngine.springs, isEmpty);
      expect(e.physicsEngine.particles, hasLength(2));
      e.physicsEngine
        ..createSpring(s.a, s.b)
        ..clear();
      expect(e.physicsEngine.springs, isEmpty);
      expect(e.physicsEngine.bodies, isEmpty);
    });

    test('many removals keep creation order and drop springs at once', () {
      final e = Flut5Engine();
      final world = e.physicsEngine;
      final ps = [
        for (var i = 0; i < 10; i++) world.createParticle(i * 1.0, 0),
      ];
      final links = [
        for (var i = 0; i + 1 < ps.length; i++)
          world.createSpring(ps[i], ps[i + 1]),
      ];
      for (var i = 0; i < ps.length; i += 2) {
        expect(world.remove(ps[i]), isTrue);
      }
      expect(world.remove(ps[0]), isFalse); // already removed
      // Every spring touched a removed particle, so all of them are gone.
      expect(world.remove(links[3]), isFalse);
      expect(world.springs, isEmpty);
      expect(world.particles, [for (var i = 1; i < 10; i += 2) ps[i]]);
      expect(world.bodies, [for (var i = 1; i < 10; i += 2) ps[i]]);
    });

    test('a spring made after its particle was removed stays registered', () {
      final e = Flut5Engine();
      final world = e.physicsEngine;
      final a = world.createParticle(0, 0);
      final b = world.createParticle(10, 0);
      world.remove(a);
      final s = world.createSpring(a, b);
      expect(world.springs, [s]);
      expect(world.remove(s), isTrue);
    });

    test('removed bodies stop stepping before the lists are read', () {
      final e = Flut5Engine();
      final world = e.physicsEngine..setGravity(1);
      final p = world.createParticle(0, 0);
      world.remove(p);
      world.update();
      expect(p.y, 0.0);
    });

    test('damped spring settles at rest length', () {
      final (e, s) = stretchedSpring();
      s.a.damping = 0.9;
      s.b.damping = 0.9;
      for (var i = 0; i < 500; i++) {
        e.physicsEngine.update();
      }
      expect(s.a.position.distanceTo(s.b.position), closeTo(50, 0.01));
    });
  });

  group('Body lists', () {
    test('a for-in loop sees every body, minus removed ones', () {
      final world = Flut5Engine().physicsEngine;
      final kept = world.createParticle(0, 0);
      final dropped = world.createParticle(1, 0);
      world.remove(dropped);
      expect([for (final p in world.particles) p], [kept]);
    });

    test('removing a body mid-loop throws, like any list', () {
      final world = Flut5Engine().physicsEngine;
      for (var i = 0; i < 3; i++) {
        world.createParticle(0, 0);
      }
      expect(() {
        for (final p in world.particles) {
          world.remove(p);
        }
      }, throwsA(isA<ConcurrentModificationError>()));
    });

    test('creating a body mid-loop throws, like any list', () {
      final world = Flut5Engine().physicsEngine..createParticle(0, 0);
      expect(() {
        for (final _ in world.particles) {
          world.createParticle(1, 1);
        }
      }, throwsA(isA<ConcurrentModificationError>()));
    });
  });

  group('Window bounds', () {
    test('off by default: particles leave the window', () {
      final e = windowed();
      final p = e.physicsEngine.createParticle(195, 50)..velocity.x = 10;
      e.physicsEngine.update();
      expect(p.x, 205.0);
      expect(e.windowBoundsRestitution(), 1.0);
    });

    test('mirrors the overshoot and reverses velocity', () {
      final e = windowed()..windowBoundsCollision();
      final p = e.physicsEngine.createParticle(195, 50)..velocity.x = 10;
      e.physicsEngine.update();
      expect(p.x, 195.0);
      expect(p.velocity.x, -10.0);
    });

    test('restitution scales the rebound', () {
      final e = windowed()
        ..windowBoundsCollision()
        ..windowBoundsRestitution(0.5);
      final p = e.physicsEngine.createParticle(5, 95)
        ..velocity.setValues(-10, 10, 0);
      e.physicsEngine.update();
      expect(p.x, 2.5); // 5 past the left edge, half of it bounced back
      expect(p.velocity.x, 5.0);
      expect(p.y, 97.5);
      expect(p.velocity.y, -5.0);
    });

    test('restitution 0 stops the particle on the wall', () {
      final e = windowed()
        ..windowBoundsCollision()
        ..windowBoundsRestitution(0);
      final p = e.physicsEngine.createParticle(50, 5)..velocity.y = -10;
      e.physicsEngine.update();
      expect(p.y, 0.0);
      expect(p.velocity.y, 0.0);
    });

    test('only the selected edges collide', () {
      final e = windowed()..windowBoundsCollision(top: false, right: false);
      final up = e.physicsEngine.createParticle(50, 5)..velocity.y = -10;
      final right = e.physicsEngine.createParticle(195, 50)..velocity.x = 10;
      final left = e.physicsEngine.createParticle(5, 50)..velocity.x = -10;
      e.physicsEngine.update();
      expect(up.y, -5.0);
      expect(right.x, 205.0);
      expect(left.x, 5.0);
      expect(left.velocity.x, 10.0);
    });

    test('all switches every edge; named edges override it', () {
      final e = windowed()..windowBoundsCollision(all: false, bottom: true);
      final up = e.physicsEngine.createParticle(50, 5)..velocity.y = -10;
      final down = e.physicsEngine.createParticle(50, 95)..velocity.y = 10;
      e.physicsEngine.update();
      expect(up.y, -5.0);
      expect(down.y, 95.0);
      expect(down.velocity.y, -10.0);

      e.windowBoundsCollision(all: false);
      down.velocity.y = 10;
      e.physicsEngine.update();
      expect(down.y, 105.0); // floor gone too: falls through
    });

    test('noWindowBoundsCollision opens every edge again', () {
      final e = windowed()
        ..windowBoundsCollision()
        ..noWindowBoundsCollision();
      final p = e.physicsEngine.createParticle(195, 50)..velocity.x = 10;
      e.physicsEngine.update();
      expect(p.x, 205.0);
    });

    test('the particle edge, not its center, touches the wall', () {
      final e = windowed()..windowBoundsCollision();
      final p = e.physicsEngine.createParticle(180, 50)
        ..radius = 15
        ..velocity.x = 10;
      e.physicsEngine.update();
      expect(p.x, 180.0); // hit at 185, bounced 5 back
      expect(p.velocity.x, -10.0);
    });

    test('a particle resting on the floor stays put without jitter', () {
      final e = windowed()
        ..windowBoundsCollision()
        ..windowBoundsRestitution(0.6);
      final world = e.physicsEngine..setGravity(0.2);
      final p = world.createParticle(100, 10)..radius = 10;
      for (var i = 0; i < 2000; i++) {
        world.update();
      }
      for (var i = 0; i < 10; i++) {
        world.update();
        expect(p.y, 90.0);
        expect(p.velocity.y, 0.0);
      }
    });

    test('restitution 1 keeps bouncing to the same height under gravity', () {
      final e = windowed()..windowBoundsCollision();
      final world = e.physicsEngine..setGravity(0.2);
      final p = world.createParticle(100, 10);
      var highest = double.infinity;
      for (var i = 0; i < 5000; i++) {
        world.update();
        if (i > 4000) highest = p.y < highest ? p.y : highest;
      }
      expect(highest, closeTo(10, 1));
    });

    test('a particle pushed outside by a resize is put back on the edge', () {
      final e = windowed()..windowBoundsCollision();
      final p = e.physicsEngine.createParticle(300, 50)..velocity.x = -2;
      e.physicsEngine.update();
      expect(p.x, 200.0);
      expect(p.velocity.x, -2.0);
    });

    test('no window yet: bounds do nothing', () {
      final e = Flut5Engine()..windowBoundsCollision();
      final p = e.physicsEngine.createParticle(5, 5)..velocity.x = -10;
      e.physicsEngine.update();
      expect(p.x, -5.0);
    });

    test('negative restitution is rejected', () {
      expect(
        () => windowed().windowBoundsRestitution(-0.1),
        throwsArgumentError,
      );
    });
  });

  group('Particle collision', () {
    /// Two particles of radius 5 on a horizontal line, [gap] apart after
    /// this frame's step, closing in at [speed] each.
    (Flut5Engine, Flut5PhysicsParticle, Flut5PhysicsParticle) headOn({
      double massA = 1,
      double massB = 1,
      double vy = 0,
    }) {
      final e = Flut5Engine()..particleCollision();
      final a = e.physicsEngine.createParticle(100, 50)
        ..radius = 5
        ..mass = massA
        ..velocity.setValues(2, vy, 0);
      final b = e.physicsEngine.createParticle(110, 50)
        ..radius = 5
        ..mass = massB
        ..velocity.setValues(-2, vy, 0);
      return (e, a, b);
    }

    test('off by default: particles pass through each other', () {
      final (e, a, b) = headOn();
      e.noParticleCollision();
      e.physicsEngine.update();
      expect(a.x, 102.0);
      expect(b.x, 108.0);
      expect(a.velocity.x, 2.0);
      expect(Flut5Engine().particleRestitution(), 1.0);
    });

    test('equal masses, restitution 1: separated and velocities swap', () {
      final (e, a, b) = headOn();
      e.physicsEngine.update();
      expect(a.x, 100.0); // overlapped 4 after the step, 2 back each
      expect(b.x, 110.0);
      expect(a.velocity.x, -2.0);
      expect(b.velocity.x, 2.0);
    });

    test('restitution 0 stops them along the hit', () {
      final (e, a, b) = headOn();
      e.particleRestitution(0);
      e.physicsEngine.update();
      expect(a.velocity.x, 0.0);
      expect(b.velocity.x, 0.0);
    });

    test('the lighter particle moves more; momentum and energy kept', () {
      final (e, a, b) = headOn(massA: 3);
      e.physicsEngine.update();
      expect(a.x, closeTo(101, 1e-9)); // 1 of the 4 overlap
      expect(b.x, closeTo(111, 1e-9)); // the other 3
      expect(a.velocity.x, closeTo(0, 1e-9));
      expect(b.velocity.x, closeTo(4, 1e-9));
      // Before: 3·2 + 1·(−2) = 4 momentum, ½·3·4 + ½·1·4 = 8 energy.
      expect(3 * a.velocity.x + b.velocity.x, closeTo(4, 1e-9));
      expect(
        1.5 * a.velocity.x * a.velocity.x + 0.5 * b.velocity.x * b.velocity.x,
        closeTo(8, 1e-9),
      );
    });

    test('only the velocity along the hit changes', () {
      final (e, a, b) = headOn(vy: 1);
      e.physicsEngine.update();
      expect(a.velocity.x, -2.0);
      expect(a.velocity.y, 1.0);
      expect(b.velocity.y, 1.0);
    });

    test('overlapping but separating: pushed apart, no bounce', () {
      final e = Flut5Engine()..particleCollision();
      final a = e.physicsEngine.createParticle(100, 50)
        ..radius = 5
        ..velocity.x = -1;
      final b = e.physicsEngine.createParticle(106, 50)
        ..radius = 5
        ..velocity.x = 1;
      e.physicsEngine.update();
      expect(b.x - a.x, closeTo(10, 1e-9));
      expect(a.velocity.x, -1.0);
      expect(b.velocity.x, 1.0);
    });

    test('radius 0 collides only with particles that have a radius', () {
      final e = Flut5Engine()..particleCollision();
      final p1 = e.physicsEngine.createParticle(100, 50);
      final p2 = e.physicsEngine.createParticle(100, 50);
      e.physicsEngine.update();
      expect(p1.x, 100.0);
      expect(p2.x, 100.0);

      final big = e.physicsEngine.createParticle(103, 50)..radius = 5;
      e.physicsEngine.update();
      expect(big.x - p1.x, greaterThanOrEqualTo(5 - 1e-9));
      expect(big.x - p2.x, greaterThanOrEqualTo(5 - 1e-9));
    });

    test('particles exactly on top of each other are split along x', () {
      final e = Flut5Engine()..particleCollision();
      final a = e.physicsEngine.createParticle(100, 50)..radius = 5;
      final b = e.physicsEngine.createParticle(100, 50)..radius = 5;
      e.physicsEngine.update();
      expect(a.x, 95.0);
      expect(b.x, 105.0);
      expect(a.y, 50.0);
    });

    test('a column resting on the floor settles inside the window', () {
      final e = windowed()
        ..windowBoundsCollision()
        ..particleCollision()
        ..windowBoundsRestitution(0.5)
        ..particleRestitution(0.5);
      final world = e.physicsEngine..setGravity(0.2);
      final column = [
        for (var i = 0; i < 3; i++)
          world.createParticle(100, 15 + i * 25.0)..radius = 10,
      ];
      for (var i = 0; i < 3000; i++) {
        world.update();
      }
      for (final p in column) {
        expect(p.y + p.radius, lessThanOrEqualTo(100 + 1e-9));
      }
      final ys = column.map((p) => p.y).toList()..sort();
      expect(ys.last, 90.0); // bottom one sits on the floor
      expect(ys[2] - ys[1], greaterThan(19)); // overlap under 1 px
      expect(ys[1] - ys[0], greaterThan(19));
    });

    test('finds every touching pair, whatever the sizes or creation order', () {
      // 200 pairs on a 20 × 10 grid of 300 px cells, each pair overlapping
      // by 1 px and far from the others. Columns of pairs share the same
      // strip of x, and radii from 1 to 40 make big particles start left of
      // small ones that sit further left.
      final random = math.Random(7);
      final e = Flut5Engine()..particleCollision(iterations: 1);
      final pairs = <(Flut5Vector, double, Flut5Vector, double)>[];
      for (var column = 0; column < 20; column++) {
        for (var row = 0; row < 10; row++) {
          final radiusA = 1 + random.nextDouble() * 39;
          final radiusB = 1 + random.nextDouble() * 39;
          final positionA = Flut5Vector(
            column * 300 + random.nextDouble() * 20,
            row * 300 + random.nextDouble() * 20,
          );
          final direction = random.nextDouble() * 2 * math.pi;
          final distance = radiusA + radiusB - 1;
          final positionB = Flut5Vector(
            positionA.x + math.cos(direction) * distance,
            positionA.y + math.sin(direction) * distance,
          );
          pairs.add((positionA, radiusA, positionB, radiusB));
        }
      }
      final created = <(Flut5PhysicsParticle, Flut5PhysicsParticle)>[];
      final shuffled = [...pairs]..shuffle(random);
      for (final (positionA, radiusA, positionB, radiusB) in shuffled) {
        created.add((
          e.physicsEngine.createParticle(positionA.x, positionA.y)
            ..radius = radiusA,
          e.physicsEngine.createParticle(positionB.x, positionB.y)
            ..radius = radiusB,
        ));
      }
      e.physicsEngine.update();
      for (final (a, b) in created) {
        expect(a.position.dist(b.position), closeTo(a.radius + b.radius, 1e-9));
      }
    });

    test('still finds pairs after particles are created and removed', () {
      final e = Flut5Engine()..particleCollision();
      final world = e.physicsEngine;
      final row = [
        for (var i = 0; i < 5; i++)
          world.createParticle(i * 100.0, 50)..radius = 5,
      ];
      world.update();

      // Same count, every index shifted: drop the first, add one onto the
      // last.
      world.remove(row.first);
      final newcomer = world.createParticle(398, 50)..radius = 5;
      world.update();
      expect(newcomer.position.dist(row.last.position), closeTo(10, 1e-9));

      // Fewer particles: drop two and move one just below the last.
      world
        ..remove(row[1])
        ..remove(row[2]);
      row[3].position.setValues(row.last.x, row.last.y + 8, 0);
      world.update();
      expect(row[3].y - row.last.y, closeTo(10, 1e-9));
    });

    test('particles that overtake each other still collide', () {
      // a races right past b, on a lower line, into c.
      final e = Flut5Engine()..particleCollision();
      final world = e.physicsEngine;
      final a = world.createParticle(0, 0)
        ..radius = 5
        ..velocity.x = 30;
      final b = world.createParticle(50, 100)..radius = 5;
      final c = world.createParticle(215, 0)..radius = 5;
      for (var i = 0; i < 7; i++) {
        world.update(); // a passes b on the 2nd, overlaps c by 5 on the 7th
      }
      expect(a.x, greaterThan(b.x));
      expect(c.velocity.x, 30.0);
      expect(a.velocity.x, 0.0);
    });

    test('touching pairs are found whichever way they lie, among many', () {
      // Pairs overlapping by 1 in every direction, far from each other, so
      // they straddle the borders of the search cells every which way.
      final e = Flut5Engine()..particleCollision(iterations: 1);
      final world = e.physicsEngine;
      final pairs = <(Flut5PhysicsParticle, Flut5PhysicsParticle)>[];
      final random = math.Random(4);
      for (var i = 0; i < 400; i++) {
        final x = (i % 20) * 40 + random.nextDouble() * 10;
        final y = (i ~/ 20) * 40 + random.nextDouble() * 10;
        final angle = i * math.pi / 8;
        final a = world.createParticle(x, y)..radius = 2;
        final b = world.createParticle(
          x + 3 * math.cos(angle),
          y + 3 * math.sin(angle),
        )..radius = 2;
        pairs.add((a, b));
      }
      world.update();
      for (final (a, b) in pairs) {
        expect(a.position.dist(b.position), closeTo(4, 1e-9));
      }
    });

    test('a particle much bigger than the rest collides with all of them', () {
      final e = Flut5Engine()..particleCollision(iterations: 1);
      final world = e.physicsEngine;
      // Enough small ones that the search cells are sized for them.
      for (var i = 0; i < 200; i++) {
        world.createParticle(1000 + (i % 20) * 10, (i ~/ 20) * 10).radius = 2;
      }
      final onItsEdge = [
        for (var i = 7; i < 12; i++)
          world.createParticle(
            101 * math.cos(i * math.pi / 6),
            101 * math.sin(i * math.pi / 6),
          )..radius = 2,
      ];
      final giant = world.createParticle(0, 0)
        ..radius = 100
        ..mass = 1e9;
      final lighterGiant = world.createParticle(0, 190)..radius = 100;
      world.update();
      for (final small in onItsEdge) {
        expect(small.position.dist(giant.position), closeTo(102, 1e-6));
      }
      expect(lighterGiant.y - giant.y, closeTo(200, 1e-6));
    });

    test('particles nowhere, or impossibly far apart, are left alone', () {
      final e = Flut5Engine()..particleCollision(iterations: 1);
      final world = e.physicsEngine;
      final a = world.createParticle(0, 0)..radius = 5;
      final b = world.createParticle(8, 0)..radius = 5;
      final lost = world.createParticle(double.nan, 0)..radius = 5;
      final gone = world.createParticle(double.infinity, 3)..radius = 5;
      world.update();
      expect(b.x - a.x, closeTo(10, 1e-9));
      expect(lost.x, isNaN);
      expect(gone.x, double.infinity);

      world
        ..remove(lost)
        ..remove(gone);
      a.position.setValues(0, 0, 0);
      b.position.setValues(8, 0, 0);
      final far = world.createParticle(1e300, -1e300)..radius = 5;
      final farther = world.createParticle(-1e308, 1e308)..radius = 5;
      world.update();
      expect(b.x - a.x, closeTo(10, 1e-9));
      expect(far.x, 1e300);
      expect(farther.y, 1e308);
    });

    test('invalid settings are rejected', () {
      final e = Flut5Engine();
      expect(() => e.particleRestitution(-1), throwsArgumentError);
      expect(() => e.particleCollision(iterations: 0), throwsArgumentError);
    });
  });

  group('Rotation', () {
    /// A radius-10 particle resting on the floor of a 200 × 100 window,
    /// sliding right at 3 px/frame, under gravity 0.2. Only the floor
    /// collides, with restitution 0.
    (Flut5PhysicsEngine, Flut5PhysicsParticle) slidingOnFloor(
      PhysicsRotationMode mode,
    ) {
      final e = windowed()
        ..windowBoundsCollision(all: false, bottom: true)
        ..windowBoundsRestitution(0);
      final world = e.physicsEngine
        ..setGravity(0.2)
        ..rotationMode = mode;
      final p = world.createParticle(50, 90)
        ..radius = 10
        ..velocity.x = 3;
      return (world, p);
    }

    test('none by default: the engine never turns particles', () {
      final (world, p) = slidingOnFloor(.none);
      p.angularVelocity = 0.5;
      for (var i = 0; i < 30; i++) {
        world.update();
      }
      expect(
        Flut5Engine().physicsEngine.rotationMode,
        PhysicsRotationMode.none,
      );
      expect(p.angle, 0.0);
      expect(p.angularVelocity, 0.5); // left alone
      expect(p.velocity.x, 3.0); // no friction either
    });

    test('cosmetic eases spin toward half the rolling spin by default', () {
      final world = Flut5Engine().physicsEngine..rotationMode = .cosmetic;
      final p = world.createParticle(50, 50)
        ..radius = 10
        ..velocity.x = 2;
      world.update();
      expect(p.angularVelocity, closeTo(0.005, 1e-12)); // 5% of 0.1
      expect(p.angle, closeTo(0.005, 1e-12));
      for (var i = 0; i < 500; i++) {
        world.update();
      }
      expect(p.angularVelocity, closeTo(0.1, 1e-9)); // 0.5 × 2 / 10
    });

    test('scale 0.04 × radius reproduces angleV += vx * 0.002, *= 0.95', () {
      final world = Flut5Engine().physicsEngine
        ..rotationMode = .cosmetic
        ..cosmeticSpinScale = 0.04 * 10;
      final p = world.createParticle(50, 50)
        ..radius = 10
        ..velocity.x = 2;
      var angleV = 0.0;
      for (var i = 0; i < 100; i++) {
        world.update();
        angleV = angleV * 0.95 + 2 * 0.002;
        expect(p.angularVelocity, closeTo(angleV, 1e-12));
      }
    });

    test('cosmetic spin coasts to a stop with the particle', () {
      final world = Flut5Engine().physicsEngine..rotationMode = .cosmetic;
      final p = world.createParticle(50, 50)
        ..radius = 10
        ..angularVelocity = 0.2;
      world.update();
      expect(p.angularVelocity, closeTo(0.19, 1e-12));
      for (var i = 0; i < 500; i++) {
        world.update();
      }
      expect(p.angularVelocity, closeTo(0, 1e-9));
    });

    test('cosmeticSpinScale 1 rolls exactly', () {
      final world = Flut5Engine().physicsEngine
        ..rotationMode = .cosmetic
        ..cosmeticSpinScale = 1;
      final p = world.createParticle(50, 50)
        ..radius = 10
        ..velocity.x = 2;
      for (var i = 0; i < 500; i++) {
        world.update();
      }
      expect(p.angularVelocity, closeTo(0.2, 1e-9)); // exact rolling
    });

    test('cosmeticSpinDecay 0 snaps straight to the rolling spin', () {
      final world = Flut5Engine().physicsEngine
        ..rotationMode = .cosmetic
        ..cosmeticSpinDecay = 0;
      final p = world.createParticle(50, 50)
        ..radius = 10
        ..velocity.x = 2;
      world.update();
      expect(p.angularVelocity, closeTo(0.1, 1e-12));
    });

    test('invalid cosmetic settings are rejected', () {
      final world = Flut5Engine().physicsEngine;
      expect(() => world.cosmeticSpinScale = -1, throwsArgumentError);
      expect(() => world.cosmeticSpinDecay = 1.1, throwsArgumentError);
      expect(() => world.cosmeticSpinDecay = -0.1, throwsArgumentError);
    });

    test('cosmetic leaves particles without a radius alone', () {
      final world = Flut5Engine().physicsEngine..rotationMode = .cosmetic;
      final p = world.createParticle(50, 50)..velocity.x = 2;
      world.update();
      expect(p.angle, 0.0);
    });

    test('cosmetic never changes how particles move', () {
      final (world, p) = slidingOnFloor(.cosmetic);
      for (var i = 0; i < 30; i++) {
        world.update();
      }
      expect(p.velocity.x, 3.0);
      expect(p.angularVelocity, greaterThan(0));
    });

    test('physical: a ball sliding on the floor ends up rolling', () {
      final (world, p) = slidingOnFloor(.physical);
      for (var i = 0; i < 200; i++) {
        world.update();
      }
      // A solid disc that starts sliding rolls on at two thirds the speed.
      expect(p.velocity.x, closeTo(2, 1e-9));
      expect(p.angularVelocity * p.radius, closeTo(p.velocity.x, 1e-9));
      expect(p.angle, greaterThan(0));
    });

    test('physical with friction 0: nothing grips, nothing turns', () {
      final (world, p) = slidingOnFloor(.physical);
      world.friction = 0;
      for (var i = 0; i < 30; i++) {
        world.update();
      }
      expect(p.velocity.x, 3.0);
      expect(p.angularVelocity, 0.0);
    });

    test('physical: a spinning ball kicks sideways when it lands', () {
      final e = windowed()
        ..windowBoundsCollision()
        ..windowBoundsRestitution(0.5);
      final world = e.physicsEngine
        ..setGravity(0.2)
        ..rotationMode = .physical;
      final p = world.createParticle(100, 50)
        ..radius = 10
        ..angularVelocity = 0.3; // clockwise
      for (var i = 0; i < 40; i++) {
        world.update();
      }
      expect(p.velocity.x, greaterThan(0));
      expect(p.angularVelocity, lessThan(0.3));
    });

    test('physical: damping slows spin too', () {
      final world = Flut5Engine().physicsEngine..rotationMode = .physical;
      final p = world.createParticle(50, 50)
        ..damping = 0.5
        ..angularVelocity = 1;
      world.update();
      expect(p.angularVelocity, 0.5);
      expect(p.angle, 0.5);
    });

    test('physical: a grazing hit spins both particles the same way', () {
      Flut5PhysicsParticle grazed(PhysicsRotationMode mode) {
        final e = Flut5Engine()..particleCollision();
        final world = e.physicsEngine..rotationMode = mode;
        final a = world.createParticle(100, 50)
          ..radius = 5
          ..velocity.x = 2;
        final b = world.createParticle(108, 55)..radius = 5;
        world.update();
        expect(b.angularVelocity, closeTo(a.angularVelocity, 1e-12));
        return a;
      }

      expect(grazed(.physical).angularVelocity, greaterThan(0));
      expect(grazed(.none).angularVelocity, 0.0);
    });

    test('negative friction is rejected', () {
      expect(
        () => Flut5Engine().physicsEngine.friction = -0.1,
        throwsArgumentError,
      );
    });
  });

  group('Polygons', () {
    /// A physics world with gravity [gravity], in a 400 × 300 window.
    Flut5PhysicsEngine world({double gravity = 0}) {
      final engine = Flut5Engine()
        ..environment = const SketchEnvironment().withSize(
          const Size(400, 300),
        );
      return engine.physicsEngine..setGravity(gravity);
    }

    (double, double) at(Flut5Vector v) => (v.x, v.y);

    test('createRect: centered corners, size, inertia, listed', () {
      final physics = world();
      final rect = physics.createRect(100, 50, 40, 20)..mass = 3;
      expect(physics.polygons, [rect]);
      expect(physics.bodies, [rect]);
      expect((rect.x, rect.y, rect.width, rect.height), (100, 50, 40, 20));
      expect(rect.momentOfInertia, closeTo(3 * (1600 + 400) / 12, 1e-9));
      expect(rect.corners.map(at), [
        (80.0, 40.0),
        (120.0, 40.0),
        (120.0, 60.0),
        (80.0, 60.0),
      ]);
    });

    test('corners turn with the angle, clockwise on screen', () {
      final rect = world().createRect(0, 0, 40, 20)..angle = math.pi / 2;
      final first = rect.corners.first; // (-20, -10) turned a quarter
      expect(first.x, closeTo(10, 1e-9));
      expect(first.y, closeTo(-20, 1e-9));
    });

    test('createPolygon moves the position to the center of mass', () {
      final triangle = world().createPolygon(100, 100, [
        Flut5Vector(0, 0),
        Flut5Vector(30, 0),
        Flut5Vector(0, 30),
      ]);
      expect(triangle.x, closeTo(110, 1e-9));
      expect(triangle.y, closeTo(110, 1e-9));
      final corners = triangle.corners.map(at).toList();
      expect(corners[0].$1, closeTo(100, 1e-9));
      expect(corners[1].$1, closeTo(130, 1e-9));
      expect(corners[2].$2, closeTo(130, 1e-9));
    });

    test('corners can go either way around', () {
      final corners = [
        Flut5Vector(0, 0),
        Flut5Vector(30, 0),
        Flut5Vector(0, 30),
      ];
      final forward = world().createPolygon(0, 0, corners);
      final backward = world().createPolygon(0, 0, corners.reversed.toList());
      expect(backward.localCorners.map(at), forward.localCorners.map(at));
    });

    test('shapes that are not convex polygons are rejected', () {
      final physics = world();
      expect(
        () =>
            physics.createPolygon(0, 0, [Flut5Vector(0, 0), Flut5Vector(1, 0)]),
        throwsArgumentError,
      );
      expect(
        () => physics.createPolygon(0, 0, [
          Flut5Vector(0, 0),
          Flut5Vector(0, 0),
          Flut5Vector(0, 10),
        ]),
        throwsArgumentError,
      );
      expect(
        () => physics.createPolygon(0, 0, [
          Flut5Vector(0, 0),
          Flut5Vector(10, 0),
          Flut5Vector(20, 0),
        ]),
        throwsArgumentError,
      );
      expect(
        () => physics.createPolygon(0, 0, [
          Flut5Vector(0, 0),
          Flut5Vector(40, 0),
          Flut5Vector(40, 40),
          Flut5Vector(20, 10), // the dent
          Flut5Vector(0, 40),
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('(20.0, 10.0) makes a dent'),
          ),
        ),
      );
      expect(() => physics.createRect(0, 0, 0, 10), throwsArgumentError);
    });

    test('static: no gravity, but moves by its own velocity', () {
      final physics = world(gravity: 0.2);
      final platform = physics.createRect(100, 100, 50, 10)
        ..isStatic = true
        ..velocity.x = 1;
      physics.update();
      expect((platform.x, platform.y), (101, 100));
    });

    test('a particle lands on a static platform and rests on it', () {
      final physics = world(gravity: 0.2)..polygonRestitution = 0;
      physics.createRect(200, 80, 400, 20).isStatic = true; // top at 70
      final ball = physics.createParticle(200, 20)..radius = 10;
      for (var i = 0; i < 200; i++) {
        physics.update();
      }
      expect(ball.y, closeTo(60, 1e-9));
      expect(ball.velocity.y, 0.0);
    });

    test('a particle bounces off the side of a rect', () {
      final physics = world();
      physics.createRect(100, 50, 20, 60).isStatic = true; // left side x = 90
      final ball = physics.createParticle(75, 50)
        ..radius = 10
        ..velocity.x = 7;
      physics.update(); // moves to 82: 2 into the side
      expect(ball.x, closeTo(80, 1e-9));
      expect(ball.velocity.x, closeTo(-7, 1e-9));
      expect(ball.velocity.y, closeTo(0, 1e-9));
    });

    test('a particle hitting a corner bounces back along the diagonal', () {
      final physics = world();
      physics.createRect(100, 100, 20, 20).isStatic = true; // corner (90, 90)
      final ball = physics.createParticle(77, 77)
        ..radius = 15
        ..velocity.setValues(3, 3, 0);
      physics.update();
      expect(ball.velocity.x, closeTo(-3, 1e-9));
      expect(ball.velocity.y, closeTo(-3, 1e-9));
    });

    test('a particle inside a polygon is pushed out the nearest side', () {
      final physics = world();
      physics.createRect(100, 100, 100, 20).isStatic = true; // top at 90
      final ball = physics.createParticle(100, 93)..radius = 5;
      physics.update();
      expect(ball.y, closeTo(85, 1e-9));
      expect(ball.x, 100.0);
    });

    test('a box falls onto a platform and rests flat on it', () {
      final physics = world(gravity: 0.2)
        ..rotationMode = .physical
        ..polygonRestitution = 0;
      physics.createRect(200, 200, 400, 20).isStatic = true; // top at 190
      final box = physics.createRect(200, 100, 40, 40);
      for (var i = 0; i < 300; i++) {
        physics.update();
      }
      expect(box.y, closeTo(170, 1e-6));
      expect(box.x, closeTo(200, 1e-6));
      expect(box.angle, closeTo(0, 1e-6));
    });

    test('physical: a tilted box tips over onto its face', () {
      final physics = world(gravity: 0.2)
        ..rotationMode = .physical
        ..polygonRestitution = 0;
      physics.createRect(200, 200, 400, 20).isStatic = true;
      final box = physics.createRect(200, 100, 40, 40)..angle = 0.3;
      for (var i = 0; i < 600; i++) {
        physics.update();
      }
      expect(box.angle, closeTo(0, 0.01));
      expect(box.y, closeTo(170, 0.1));
    });

    for (final mode in [
      PhysicsRotationMode.none,
      PhysicsRotationMode.cosmetic,
    ]) {
      test('${mode.name}: a tilted box lands without turning', () {
        final physics = world(gravity: 0.2)
          ..rotationMode = mode
          ..polygonRestitution = 0;
        physics.createRect(200, 200, 400, 20).isStatic = true;
        final box = physics.createRect(200, 100, 40, 40)..angle = 0.3;
        for (var i = 0; i < 300; i++) {
          physics.update();
        }
        expect(box.angle, 0.3);
        expect(box.angularVelocity, 0.0);
      });
    }

    test('equal boxes hitting head on swap velocities', () {
      final physics = world();
      final a = physics.createRect(100, 50, 20, 20)..velocity.x = 2;
      final b = physics.createRect(122, 50, 20, 20)..velocity.x = -2;
      physics.update();
      expect(a.velocity.x, closeTo(-2, 1e-9));
      expect(b.velocity.x, closeTo(2, 1e-9));
      expect(b.x - a.x, closeTo(20, 1e-9)); // pushed apart to just touching
    });

    test('physical: a head-on hit adds no spin', () {
      final physics = world()..rotationMode = .physical;
      final a = physics.createRect(100, 50, 20, 20)..velocity.x = 2;
      final b = physics.createRect(122, 50, 20, 20)..velocity.x = -2;
      physics.update();
      expect(a.angularVelocity, closeTo(0, 1e-9));
      expect(b.angularVelocity, closeTo(0, 1e-9));
      expect(a.velocity.x, closeTo(-2, 1e-6));
    });

    test('physical: an off-center hit spins both and keeps momentum', () {
      final physics = world()..rotationMode = .physical;
      final a = physics.createRect(100, 50, 20, 20)..velocity.x = 2;
      final b = physics.createRect(121, 60, 20, 20);
      physics.update();
      expect(a.angularVelocity, isNot(closeTo(0, 1e-6)));
      expect(b.angularVelocity, isNot(closeTo(0, 1e-6)));
      expect(a.velocity.x + b.velocity.x, closeTo(2, 1e-9));
      expect(a.velocity.y + b.velocity.y, closeTo(0, 1e-9));
    });

    test('a box falls to the window floor and rests on it', () {
      final physics = world(gravity: 0.2)
        ..windowBoundsCollision()
        ..windowBoundsRestitution = 0;
      final box = physics.createRect(100, 20, 20, 20);
      for (var i = 0; i < 300; i++) {
        physics.update();
      }
      expect(box.y, closeTo(290, 1e-9));
      expect(box.velocity.y, 0.0);
    });

    test('a moving box cannot push a static one', () {
      final physics = world();
      final wall = physics.createRect(100, 50, 20, 60)..isStatic = true;
      final box = physics.createRect(75, 50, 20, 20)..velocity.x = 7;
      physics.update();
      expect((wall.x, wall.y, wall.angle), (100, 50, 0));
      expect(box.velocity.x, closeTo(-7, 1e-9));
    });

    test('static polygons never collide with each other', () {
      final physics = world();
      final a = physics.createRect(100, 50, 40, 40)..isStatic = true;
      final b = physics.createRect(110, 50, 40, 40)..isStatic = true;
      physics.update();
      expect((a.x, b.x), (100, 110));
    });

    test('remove drops a polygon', () {
      final physics = world();
      final rect = physics.createRect(0, 0, 10, 10);
      expect(physics.remove(rect), isTrue);
      expect(physics.polygons, isEmpty);
      expect(physics.bodies, isEmpty);
    });

    test('collisionIterations is shared, and validated with restitution', () {
      final physics = world();
      expect(physics.collisionIterations, 2);
      physics.particleCollision(iterations: 3);
      expect(physics.collisionIterations, 3);
      physics.particleCollision(); // keeps it
      expect(physics.collisionIterations, 3);
      expect(() => physics.collisionIterations = 0, throwsArgumentError);
      expect(() => physics.polygonRestitution = -1, throwsArgumentError);
      expect(Flut5Engine().polygonRestitution(0.5), 0.5);
    });

    test('a polygon collides with the particles around it, among many', () {
      final physics = world();
      physics.createRect(200, 150, 100, 60).isStatic = true;
      // A crowd elsewhere, so only a few of the particles are near it.
      for (var i = 0; i < 300; i++) {
        physics.createParticle((i % 30) * 4.0, (i ~/ 30) * 4.0).radius = 1;
      }
      final left = physics.createParticle(149, 150)..radius = 3;
      final right = physics.createParticle(251, 160)..radius = 3;
      final above = physics.createParticle(170, 119)..radius = 3;
      final below = physics.createParticle(230, 181)..radius = 3;
      final clear = physics.createParticle(146, 150)..radius = 3;
      final big = physics.createParticle(200, 80)..radius = 50;
      physics.update();
      expect(left.x, closeTo(147, 1e-9));
      expect(right.x, closeTo(253, 1e-9));
      expect(above.y, closeTo(117, 1e-9));
      expect(below.y, closeTo(183, 1e-9));
      expect(clear.x, 146);
      expect(big.y, closeTo(70, 1e-9));
    });

    test('points with no radius still collide with polygons', () {
      final physics = world();
      physics.createRect(200, 150, 100, 60).isStatic = true;
      for (var i = 0; i < 300; i++) {
        physics.createParticle((i % 30) * 4.0, (i ~/ 30) * 4.0);
      }
      final inside = physics.createParticle(152, 150);
      physics.update();
      expect(inside.x, closeTo(150, 1e-9));
    });
  });

  group('Soft bodies', () {
    /// A physics world with gravity [gravity], in a 400 × 300 window.
    Flut5PhysicsEngine world({double gravity = 0}) {
      final engine = Flut5Engine()
        ..environment = const SketchEnvironment().withSize(
          const Size(400, 300),
        );
      return engine.physicsEngine..setGravity(gravity);
    }

    /// Every particle's position, to compare before and after a step.
    List<(double, double)> positions(Flut5PhysicsSoftBody body) => [
      for (final p in body.particles) (p.x, p.y),
    ];

    /// Expects [actual] positions to match [expected] within [tolerance].
    void expectPositions(
      List<(double, double)> actual,
      List<(double, double)> expected, {
      double tolerance = 1e-9,
    }) {
      expect(actual, hasLength(expected.length));
      for (var i = 0; i < actual.length; i++) {
        expect(actual[i].$1, closeTo(expected[i].$1, tolerance), reason: '#$i');
        expect(actual[i].$2, closeTo(expected[i].$2, tolerance), reason: '#$i');
      }
    }

    /// Bounding box size of [body]'s particle centers.
    (double, double) size(Flut5PhysicsSoftBody body) {
      final xs = body.particles.map((p) => p.x);
      final ys = body.particles.map((p) => p.y);
      return (
        xs.reduce(math.max) - xs.reduce(math.min),
        ys.reduce(math.max) - ys.reduce(math.min),
      );
    }

    /// How many grid cells of [rect] are turned inside out.
    int flippedCells(Flut5PhysicsSoftRect rect) {
      var flipped = 0;
      for (var row = 0; row + 1 < rect.rows; row++) {
        for (var column = 0; column + 1 < rect.columns; column++) {
          final topLeft = rect.particleAt(column, row);
          final topRight = rect.particleAt(column + 1, row);
          final bottomRight = rect.particleAt(column + 1, row + 1);
          final bottomLeft = rect.particleAt(column, row + 1);
          final crossDiagonals =
              (bottomRight.x - topLeft.x) * (bottomLeft.y - topRight.y) -
              (bottomRight.y - topLeft.y) * (bottomLeft.x - topRight.x);
          if (crossDiagonals < 0) flipped++;
        }
      }
      return flipped;
    }

    test('createSoftRect: a registered grid with corners on the rect', () {
      final physics = world();
      final rect = physics.createSoftRect(200, 100, 160, 100, resolution: 8);
      expect((rect.columns, rect.rows), (8, 5));
      expect((rect.width, rect.height), (160, 100));
      expect(rect.particles, hasLength(40));
      final topLeft = rect.particleAt(0, 0);
      final bottomRight = rect.particleAt(7, 4);
      expect((topLeft.x, topLeft.y), (120, 50));
      expect((bottomRight.x, bottomRight.y), (280, 150));

      expect(physics.softBodies, [rect]);
      expect(physics.particles, rect.particles);
      expect(physics.bodies, [rect, ...rect.particles]);
      expect(physics.springs, isEmpty); // its springs are its own
      // Across, down, both diagonals, and two steps across and down.
      expect(rect.springs, hasLength(35 + 32 + 2 * 28 + 30 + 24));
      for (final spring in rect.springs) {
        expect(
          spring.restLength,
          spring.a.position.distanceTo(spring.b.position),
        );
      }
    });

    test('resolution counts particles along the longer side', () {
      final physics = world();
      Flut5PhysicsSoftRect grid(double w, double h, int resolution) =>
          physics.createSoftRect(0, 0, w, h, resolution: resolution);
      final tall = grid(40, 200, 8);
      expect((tall.columns, tall.rows), (2, 8));
      final square = grid(100, 100, 5);
      expect((square.columns, square.rows), (5, 5));
      final strip = grid(300, 10, 6);
      expect((strip.columns, strip.rows), (6, 2)); // never fewer than 2
      final smallest = grid(50, 50, 2);
      expect(smallest.particles, hasLength(4));
    });

    test('particleRadius defaults to half the gap between neighbors', () {
      final physics = world();
      // Gaps: 160 / 7 across, 100 / 4 down — the smaller one counts.
      final touching = physics.createSoftRect(0, 0, 160, 100);
      for (final p in touching.particles) {
        expect(p.radius, closeTo(160 / 7 / 2, 1e-9));
      }
      final sized = physics.createSoftRect(0, 0, 160, 100, particleRadius: 3);
      expect(sized.particles.every((p) => p.radius == 3), isTrue);
    });

    test('outline runs clockwise around the edge from the top-left', () {
      final rect = world().createSoftRect(0, 0, 100, 100, resolution: 3);
      Flut5PhysicsParticle at(int column, int row) =>
          rect.particleAt(column, row);
      expect(rect.outline, [
        at(0, 0), at(1, 0), at(2, 0), //
        at(2, 1), at(2, 2), at(1, 2), //
        at(0, 2), at(0, 1),
      ]);
    });

    test('its particles know their soft body; loose ones have none', () {
      final physics = world();
      final rect = physics.createSoftRect(0, 0, 50, 50);
      expect(rect.particles.every((p) => p.softBody == rect), isTrue);
      expect(physics.createParticle(0, 0).softBody, isNull);
    });

    test('invalid settings are rejected', () {
      final physics = world();
      expect(() => physics.createSoftRect(0, 0, 0, 10), throwsArgumentError);
      expect(
        () => physics.createSoftRect(0, 0, 10, 10, resolution: 1),
        throwsArgumentError,
      );
      expect(
        () => physics.createSoftRect(0, 0, 10, 10, particleRadius: -1),
        throwsArgumentError,
      );
      expect(
        () => physics.createSoftRect(0, 0, 10, 10, stiffness: 1.1),
        throwsArgumentError,
      );
      final rect = physics.createSoftRect(0, 0, 10, 10, resolution: 3);
      expect(() => rect.stiffness = -0.1, throwsArgumentError);
      expect(() => rect.particleAt(3, 0), throwsRangeError);
      expect(() => rect.particleAt(0, -1), throwsRangeError);
      expect(physics.softBodies, [rect]); // the failed ones never registered
    });

    test('left alone it keeps its shape exactly', () {
      final physics = world();
      final rect = physics.createSoftRect(200, 150, 120, 80);
      final before = positions(rect);
      for (var i = 0; i < 100; i++) {
        physics.update();
      }
      expectPositions(positions(rect), before);
    });

    test('squashed, it springs back and stops without turning', () {
      final physics = world();
      final rect = physics.createSoftRect(200, 150, 120, 80, stiffness: 0.3);
      for (var column = 0; column < rect.columns; column++) {
        rect.particleAt(column, 0).y += 30; // flatten the top row inward
      }
      for (var i = 0; i < 300; i++) {
        physics.update();
      }
      // Back in shape: every spring at its rest length.
      for (final spring in rect.springs) {
        final length = spring.a.position.distanceTo(spring.b.position);
        expect(length, closeTo(spring.restLength, 1e-3));
      }
      expect(flippedCells(rect), 0);
      // At rest, not slowly spinning: the springs only push its particles
      // against each other, which can't turn the body as a whole.
      for (final p in rect.particles) {
        expect(p.velocity.mag(), lessThan(1e-6));
      }
      final resting = positions(rect);
      for (var i = 0; i < 600; i++) {
        physics.update();
      }
      expectPositions(positions(rect), resting, tolerance: 1e-6);
    });

    test('its springs keep a spinning body spinning, not faster', () {
      final physics = world();
      final rect = physics.createSoftRect(200, 150, 120, 80);
      // Spin it a little around its center, clockwise on screen.
      for (final p in rect.particles) {
        p.velocity.setValues(-(p.y - 150) * 0.01, (p.x - 200) * 0.01, 0);
      }
      double angularMomentum() {
        var sum = 0.0;
        final count = rect.particles.length;
        final (cx, cy) = (
          rect.particles.map((p) => p.x).reduce((a, b) => a + b) / count,
          rect.particles.map((p) => p.y).reduce((a, b) => a + b) / count,
        );
        for (final p in rect.particles) {
          sum += (p.x - cx) * p.velocity.y - (p.y - cy) * p.velocity.x;
        }
        return sum;
      }

      final before = angularMomentum();
      for (var i = 0; i < 300; i++) {
        physics.update();
      }
      expect(angularMomentum(), closeTo(before, before.abs() * 1e-9));
      expect(size(rect).$1, lessThan(150)); // it really turned
    });

    test('stiffness 0 leaves the particles loose', () {
      final physics = world();
      final rect = physics.createSoftRect(200, 150, 120, 80, stiffness: 0);
      rect.particleAt(0, 0).x -= 30;
      final before = positions(rect);
      physics.update();
      expectPositions(positions(rect), before);
    });

    test('it falls to the floor, keeps its shape and rests there', () {
      final physics = world(gravity: 0.3)
        ..windowBoundsCollision()
        ..windowBoundsRestitution = 0.3;
      final rect = physics.createSoftRect(200, 100, 160, 100);
      for (var i = 0; i < 600; i++) {
        physics.update();
      }
      final (width, height) = size(rect);
      expect(width, closeTo(160, 5));
      expect(height, closeTo(100, 5));
      final radius = rect.particles.first.radius;
      for (final p in rect.particles) {
        expect(p.y, lessThanOrEqualTo(300 - radius + 1e-9));
      }
      // Resting: not a pixel of drift over another second.
      final resting = positions(rect);
      for (var i = 0; i < 60; i++) {
        physics.update();
      }
      expectPositions(positions(rect), resting, tolerance: 1e-6);
    });

    test('a softer body squashes deeper on landing', () {
      double deepestSquash(double stiffness) {
        final physics = world(gravity: 0.3)..windowBoundsCollision();
        final rect = physics.createSoftRect(
          200,
          100,
          160,
          100,
          stiffness: stiffness,
        );
        var lowest = double.infinity;
        for (var i = 0; i < 200; i++) {
          physics.update();
          lowest = math.min(lowest, size(rect).$2);
        }
        return lowest;
      }

      final loose = deepestSquash(0.1);
      final medium = deepestSquash(0.3);
      final firm = deepestSquash(1);
      expect(loose, lessThan(medium));
      expect(medium, lessThan(firm));
      expect(loose, lessThan(80)); // it visibly gives…
      expect(firm, greaterThan(85)); // …or barely does
    });

    test('a hard landing cannot leave a fine grid folded over', () {
      // Landing at ~9.5 px a frame on 8 px cells: rows near the floor pass
      // each other for a frame or two, and springs alone would hold them
      // there, folded.
      final physics = world(gravity: 0.3)
        ..windowBoundsCollision()
        ..windowBoundsRestitution = 0.3;
      final rect = physics.createSoftRect(200, 100, 160, 100, resolution: 20);
      for (var i = 0; i < 600; i++) {
        physics.update();
      }
      expect(flippedCells(rect), 0);
      expect(size(rect).$2, closeTo(100, 5));
    });

    test('its particles pass through each other, not other particles', () {
      final physics = world()..particleCollision();
      // Radius 30 overlaps every neighbor 25 px away.
      final rect = physics.createSoftRect(
        200,
        150,
        100,
        100,
        resolution: 5,
        particleRadius: 30,
      );
      final before = positions(rect);
      physics.update();
      expectPositions(positions(rect), before);

      final intruder = physics.createParticle(150, 160)..radius = 5;
      physics.update();
      expect(intruder.x, isNot(150)); // pushed out by the corner particle
    });

    test('it lands on a static platform and rests on it', () {
      final physics = world(gravity: 0.3);
      physics.createRect(200, 250, 300, 20).isStatic = true;
      physics.polygonRestitution = 0;
      final rect = physics.createSoftRect(200, 100, 120, 80);
      for (var i = 0; i < 400; i++) {
        physics.update();
      }
      final platformTop = 240.0;
      for (var column = 0; column < rect.columns; column++) {
        final p = rect.particleAt(column, rect.rows - 1);
        expect(p.y + p.radius, closeTo(platformTop, 1));
      }
      expect(size(rect).$2, closeTo(80, 4));
    });

    test('remove takes its particles with it', () {
      final physics = world();
      final rect = physics.createSoftRect(0, 0, 50, 50);
      final loose = physics.createParticle(0, 0);
      expect(physics.remove(rect), isTrue);
      expect(physics.softBodies, isEmpty);
      expect(physics.particles, [loose]);
      expect(physics.bodies, [loose]);
      expect(physics.remove(rect), isFalse);
      physics.update(); // nothing left to pull
    });

    test('removing one particle tears it; its springs stop pulling', () {
      final physics = world();
      final rect = physics.createSoftRect(200, 150, 120, 80);
      final corner = rect.particleAt(0, 0);
      expect(physics.remove(corner), isTrue);
      expect(physics.particles, isNot(contains(corner)));
      corner.position.setValues(1000, 1000, 0); // far away, but gone
      final before = positions(rect);
      for (var i = 0; i < 30; i++) {
        physics.update();
      }
      // Nothing dragged toward it.
      expectPositions(positions(rect).sublist(1), before.sublist(1));
      expect((corner.x, corner.y), (1000, 1000)); // and it isn't stepped
    });

    /// How far [now] is from the shape [rest] made, once the rest shape is
    /// moved and turned to fit as closely as it can: the leftover distance
    /// per particle, as a share of the shape's size. `0` = same shape.
    double shapeError(
      List<(double, double)> rest,
      List<Flut5PhysicsParticle> now,
    ) {
      final count = rest.length;
      var restCenterX = 0.0, restCenterY = 0.0, centerX = 0.0, centerY = 0.0;
      for (var i = 0; i < count; i++) {
        restCenterX += rest[i].$1 / count;
        restCenterY += rest[i].$2 / count;
        centerX += now[i].x / count;
        centerY += now[i].y / count;
      }
      var sine = 0.0, cosine = 0.0, size = 0.0;
      for (var i = 0; i < count; i++) {
        final restX = rest[i].$1 - restCenterX;
        final restY = rest[i].$2 - restCenterY;
        final nowX = now[i].x - centerX, nowY = now[i].y - centerY;
        sine += restX * nowY - restY * nowX;
        cosine += restX * nowX + restY * nowY;
        size += restX * restX + restY * restY;
      }
      final turn = math.atan2(sine, cosine);
      var error = 0.0;
      for (var i = 0; i < count; i++) {
        final restX = rest[i].$1 - restCenterX;
        final restY = rest[i].$2 - restCenterY;
        final fitX = restX * math.cos(turn) - restY * math.sin(turn);
        final fitY = restX * math.sin(turn) + restY * math.cos(turn);
        final dx = now[i].x - centerX - fitX, dy = now[i].y - centerY - fitY;
        error += dx * dx + dy * dy;
      }
      return math.sqrt(error / size);
    }

    /// A 10-pointed star outline: tips 70 from the middle, dents 30.
    List<Flut5Vector> star() => [
      for (var i = 0; i < 10; i++)
        Flut5Vector.fromAngle(
          i * math.pi / 5 - math.pi / 2,
          i.isEven ? 70 : 30,
        ),
    ];

    /// The signed area inside [outline]: positive clockwise on screen.
    double signedArea(List<Flut5PhysicsParticle> outline) {
      var doubleArea = 0.0;
      for (var i = 0; i < outline.length; i++) {
        final a = outline[i], b = outline[(i + 1) % outline.length];
        doubleArea += a.x * b.y - b.x * a.y;
      }
      return doubleArea / 2;
    }

    test('createSoftBody: your own particles, springs, areas and outline', () {
      final physics = world();
      final body = physics.createSoftBody(
        200,
        100,
        [
          Flut5Vector(0, -40),
          Flut5Vector(40, 30),
          Flut5Vector(-40, 30),
          Flut5Vector(0, 7),
        ],
        springs: [(0, 1), (1, 2), (2, 0), (0, 3), (1, 3), (2, 3)],
        areas: [
          [0, 1, 3],
          [1, 2, 3],
          [2, 0, 3],
        ],
        outline: [0, 1, 2],
      );
      expect(physics.softBodies, [body]);
      expect(physics.particles, body.particles);
      expect(
        [for (final p in body.particles) (p.x, p.y)],
        [(200, 60), (240, 130), (160, 130), (200, 107)],
      );
      expect(body.springs.map((s) => (s.a, s.b)).first, (
        body.particles[0],
        body.particles[1],
      ));
      expect(body.areas, hasLength(3));
      expect(body.areas.first.particles, [
        body.particles[0],
        body.particles[1],
        body.particles[3],
      ]);
      expect(body.outline, body.particles.sublist(0, 3));
      expect(body.keepShape, isTrue);
      // Each particle's radius is half the shortest spring.
      final shortest = body.springs.map((s) => s.restLength).reduce(math.min);
      expect(body.particles.first.radius, closeTo(shortest / 2, 1e-9));
    });

    test('createSoftBody rejects a broken structure', () {
      final physics = world();
      final points = [
        Flut5Vector(0, 0),
        Flut5Vector(10, 0),
        Flut5Vector(0, 10),
      ];
      expect(
        () => physics.createSoftBody(0, 0, points, springs: [(0, 3)]),
        throwsRangeError,
      );
      expect(
        () => physics.createSoftBody(0, 0, points, springs: [(1, 1)]),
        throwsArgumentError,
      );
      expect(
        () => physics.createSoftBody(
          0,
          0,
          points,
          areas: [
            [0, 1],
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => physics.createSoftBody(0, 0, points, outline: [5]),
        throwsRangeError,
      );
      expect(physics.softBodies, isEmpty);
    });

    test('an area remembers which way it runs', () {
      final physics = world();
      final points = [
        Flut5Vector(0, 0),
        Flut5Vector(10, 0),
        Flut5Vector(0, 10),
      ];
      final body = physics.createSoftBody(
        0,
        0,
        points,
        areas: [
          [0, 1, 2],
          [0, 2, 1],
        ],
      );
      expect(body.areas.map((a) => a.restArea), [50, -50]);
    });

    test('createSoftPolygon spreads the extra particles by edge length', () {
      final physics = world();
      // A 200 × 50 bar: 6 extra particles, 2.4 for each long side and 0.6
      // for each short one — the short sides win the rounding.
      final bar = physics.createSoftPolygon(100, 100, [
        Flut5Vector(-100, -25),
        Flut5Vector(100, -25),
        Flut5Vector(100, 25),
        Flut5Vector(-100, 25),
      ], resolution: 10);
      expectPositions(positions(bar), [
        (0, 75), (200 / 3, 75), (400 / 3, 75), (200, 75), // top: 2 extra
        (200, 100), // right side: 1 extra
        (200, 125), (400 / 3, 125), (200 / 3, 125), (0, 125), // bottom
        (0, 100), // left side
      ]);
      expect(bar.outline, bar.particles);
      expect(bar.springs, hasLength(20)); // next along, and the one after
      expect(bar.areas.single.particles, bar.particles); // the whole inside
      for (final p in bar.particles) {
        expect(p.radius, closeTo(25 / 2, 1e-9)); // half the shortest gap
      }
    });

    test('createSoftPolygon runs the outline clockwise either way', () {
      final physics = world();
      final corners = star();
      final forward = physics.createSoftPolygon(0, 0, corners);
      final backward = physics.createSoftPolygon(
        0,
        0,
        corners.reversed.toList(),
      );
      expect(signedArea(forward.outline), greaterThan(0));
      expect(signedArea(backward.outline), greaterThan(0));
      expect(
        signedArea(backward.outline),
        closeTo(signedArea(forward.outline), 1e-9),
      );
      expect(forward.particles, hasLength(10)); // one per corner by default
    });

    test('createSoftCircle puts its particles evenly around the circle', () {
      final blob = world().createSoftCircle(200, 100, 50, resolution: 12);
      expect(blob.particles, hasLength(12));
      for (final p in blob.particles) {
        expect(
          math.sqrt(math.pow(p.x - 200, 2) + math.pow(p.y - 100, 2)),
          closeTo(50, 1e-9),
        );
      }
      expect(signedArea(blob.outline), greaterThan(0));
    });

    test('invalid outlines are rejected', () {
      final physics = world();
      Flut5Vector at(double x, double y) => Flut5Vector(x, y);
      expect(
        () => physics.createSoftPolygon(0, 0, [at(0, 0), at(10, 0)]),
        throwsArgumentError,
      );
      expect(
        () => physics.createSoftPolygon(0, 0, [at(0, 0), at(0, 0), at(0, 9)]),
        throwsArgumentError,
      );
      expect(
        () => physics.createSoftPolygon(0, 0, [at(0, 0), at(5, 0), at(9, 0)]),
        throwsArgumentError, // no area
      );
      expect(
        () => physics.createSoftPolygon(0, 0, [
          at(0, 0), at(10, 10), at(10, 0), at(0, 10), // a bow tie
        ]),
        throwsArgumentError,
      );
      expect(
        () => physics.createSoftPolygon(0, 0, star(), resolution: 9),
        throwsArgumentError, // fewer than the 10 corners
      );
      expect(() => physics.createSoftCircle(0, 0, 0), throwsArgumentError);
      expect(
        () => physics.createSoftCircle(0, 0, 10, resolution: 2),
        throwsArgumentError,
      );
      expect(physics.softBodies, isEmpty);
    });

    test('a soft star lands, squashes and gets its points back', () {
      final physics = world(gravity: 0.3)
        ..windowBoundsCollision()
        ..windowBoundsRestitution = 0.3;
      final softStar = physics.createSoftPolygon(
        200,
        100,
        star(),
        resolution: 40,
      );
      final rest = positions(softStar);
      var worst = 0.0;
      for (var i = 0; i < 900; i++) {
        physics.update();
        worst = math.max(worst, shapeError(rest, softStar.particles));
      }
      expect(worst, greaterThan(0.05)); // it really squashed…
      expect(shapeError(rest, softStar.particles), lessThan(0.04)); // …and back
      expect(signedArea(softStar.outline), greaterThan(0)); // never inside out
      final resting = positions(softStar);
      for (var i = 0; i < 60; i++) {
        physics.update();
      }
      expectPositions(positions(softStar), resting, tolerance: 1e-6);
    });

    test('without keepShape an outline-only blob slumps like a balloon', () {
      double restingError({required bool keepShape}) {
        final physics = world(gravity: 0.3)
          ..windowBoundsCollision()
          ..windowBoundsRestitution = 0.3;
        final blob = physics.createSoftCircle(200, 100, 60)
          ..keepShape = keepShape;
        final rest = positions(blob);
        for (var i = 0; i < 900; i++) {
          physics.update();
        }
        return shapeError(rest, blob.particles);
      }

      expect(restingError(keepShape: true), lessThan(0.05));
      expect(restingError(keepShape: false), greaterThan(0.15));
    });

    test('keepShape holds up even a loose, tall grid', () {
      final physics = world(gravity: 0.3)
        ..windowBoundsCollision()
        ..windowBoundsRestitution = 0.3;
      final rect = physics.createSoftRect(200, 100, 120, 120, stiffness: 0.1);
      for (var i = 0; i < 900; i++) {
        physics.update();
      }
      expect(size(rect).$2, greaterThan(0.9 * 120));
      expect(flippedCells(rect), 0);
    });

    test('keepShape never moves or turns a body back', () {
      final physics = world();
      final blob = physics.createSoftPolygon(200, 150, star(), resolution: 20);
      // Carry it somewhere else, turned a quarter, without bending it.
      for (final p in blob.particles) {
        final offsetX = p.x - 200, offsetY = p.y - 150;
        p.position.setValues(300 - offsetY, 100 + offsetX, 0);
      }
      final moved = positions(blob);
      for (var i = 0; i < 30; i++) {
        physics.update();
      }
      expectPositions(positions(blob), moved, tolerance: 1e-6);
    });

    test('clear drops soft bodies too', () {
      final physics = world();
      physics.createSoftRect(0, 0, 50, 50);
      physics.clear();
      expect(physics.softBodies, isEmpty);
      expect(physics.particles, isEmpty);
    });
  });
}
