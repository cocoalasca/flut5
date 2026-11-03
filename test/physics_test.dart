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
  });
}
