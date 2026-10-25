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
}
