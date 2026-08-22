import 'package:flutter_test/flutter_test.dart';
import 'package:flut5/flut5.dart';

// Create a dummy vehicle to test the mixin
class Vehicle with Flut5Steering {}

void main() {
  group('Flut5Steering Physics', () {
    test('initializes with zero vectors', () {
      final v = Vehicle();
      expect(v.position.x, 0.0);
      expect(v.velocity.x, 0.0);
      expect(v.acceleration.x, 0.0);
      expect(v.maxVelocity, 4.0);
      expect(v.maxForce, 0.1);
    });

    test('applyForce accumulates acceleration', () {
      final v = Vehicle();
      v.applyForce(Flut5Vector(2, 3));
      v.applyForce(Flut5Vector(1, -1));
      expect(v.acceleration.x, 3.0);
      expect(v.acceleration.y, 2.0);
    });

    test('configSteering updates limitations', () {
      final v = Vehicle();
      v.configSteering(maxVelocity: 10.0, maxForce: 2.0);
      expect(v.maxVelocity, 10.0);
      expect(v.maxForce, 2.0);
    });

    test('configSteering leaves omitted limits untouched', () {
      final v = Vehicle();
      v.configSteering(maxVelocity: 10.0, maxForce: 2.0);

      v.configSteering(maxVelocity: 20.0);
      expect(v.maxVelocity, 20.0);
      expect(v.maxForce, 2.0);

      v.configSteering(maxForce: 3.0);
      expect(v.maxVelocity, 20.0);
      expect(v.maxForce, 3.0);

      v.configSteering();
      expect(v.maxVelocity, 20.0);
      expect(v.maxForce, 3.0);
    });
  });

  group('Flut5Steering Behaviors', () {
    test('seek generates force towards target', () {
      final v = Vehicle();
      v.position.setValues(0, 0, 0);

      // Target is directly to the right
      v.applyForce(v.seek(Flut5Vector(100, 0)));

      // Acceleration should be pointing right (x > 0, y == 0)
      expect(v.acceleration.x, greaterThan(0.0));
      expect(v.acceleration.y, 0.0);

      // The applied force should be limited by maxForce
      expect(v.acceleration.mag(), closeTo(v.maxForce, 0.001));
    });

    test('arrive slows down within slowingRadius', () {
      final vFar = Vehicle()..configSteering(maxVelocity: 4.0, maxForce: 10.0);
      vFar.position.setValues(0, 0, 0);
      vFar.applyForce(vFar.arrive(Flut5Vector(200, 0))); // Outside default 100 slowingRadius

      final vNear = Vehicle()..configSteering(maxVelocity: 4.0, maxForce: 10.0);
      vNear.position.setValues(0, 0, 0);
      vNear.applyForce(vNear.arrive(Flut5Vector(50, 0))); // Inside default 100 slowingRadius

      // Inline physics update
      vFar.velocity.add(vFar.acceleration);
      vFar.velocity.limit(vFar.maxVelocity);
      vNear.velocity.add(vNear.acceleration);
      vNear.velocity.limit(vNear.maxVelocity);

      // Both should move right, but near should be slower
      expect(vFar.velocity.x, greaterThan(vNear.velocity.x));
    });
    test('flee generates force away from target within radius', () {
      final v = Vehicle();
      v.position.setValues(0, 0, 0);

      // Target is directly to the right, within the radius
      v.applyForce(v.flee(Flut5Vector(20, 0), fleeRadius: 50.0));

      // Force should be pointing LEFT (x < 0) since the target is on the right
      expect(v.acceleration.x, lessThan(0.0));
      expect(v.acceleration.y, 0.0);
    });

    test('flee ignores targets outside radius', () {
      final v = Vehicle();
      v.position.setValues(0, 0, 0);

      // Target is outside the radius
      v.applyForce(v.flee(Flut5Vector(100, 0), fleeRadius: 50.0));

      // No force should be applied
      expect(v.acceleration.x, 0.0);
      expect(v.acceleration.y, 0.0);
      expect(v.acceleration.z, 0.0);
    });

    test('flee with no radius always applies a force', () {
      final v = Vehicle();
      v.position.setValues(0, 0, 0);

      // Far away, but no radius given — the force is still produced
      v.applyForce(v.flee(Flut5Vector(1000, 0)));

      expect(v.acceleration.x, lessThan(0.0));
      expect(v.acceleration.y, 0.0);
    });

    test('flee reverses the desired velocity, not the whole steering force', () {
      final target = Flut5Vector(37, -19);

      final v = Vehicle();
      v.position.setValues(3, 5, 0);
      v.velocity.setValues(1, -2, 0);
      final fleeForce = v.flee(target, returnCopy: true);

      // desired = setMag(position - target, maxVelocity); steer = desired - velocity
      final expected = Flut5Vector(3, 5)
          .sub(Flut5Vector(37, -19))
          .setMag(v.maxVelocity)
          .sub(Flut5Vector(1, -2))
          .limit(v.maxForce);

      expect(fleeForce.x, closeTo(expected.x, 1e-12));
      expect(fleeForce.y, closeTo(expected.y, 1e-12));
      expect(fleeForce.z, closeTo(expected.z, 1e-12));
    });

    test('flee still steers away when charging the target at max speed', () {
      final v = Vehicle();
      v.position.setValues(0, 0, 0);
      // Moving straight at the target at full speed — the case where negating
      // seek would have produced zero force.
      v.velocity.setValues(v.maxVelocity, 0, 0);

      final fleeForce = v.flee(Flut5Vector(20, 0), returnCopy: true);

      expect(fleeForce.x, closeTo(-v.maxForce, 1e-12));
      expect(fleeForce.y, closeTo(0.0, 1e-12));
    });
  });
}
