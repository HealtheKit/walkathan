import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/features/activity/step_math.dart';

void main() {
  test('uses height for stride when known, a default otherwise', () {
    expect(StepMath.strideMeters(170), closeTo(0.7055, 0.001));
    expect(StepMath.strideMeters(null), StepMath.defaultStrideM);
    expect(StepMath.strideMeters(10), StepMath.defaultStrideM); // implausible
    expect(StepMath.strideMeters(999), StepMath.defaultStrideM);
  });

  test('distance scales with steps', () {
    expect(StepMath.distanceMeters(0), 0);
    expect(StepMath.distanceMeters(10000), 7620);
    expect(StepMath.distanceMeters(10000, heightCm: 180), 7470);
  });

  test('calories use weight and are sensible for 10k steps', () {
    final adult = StepMath.kcal(10000);
    expect(adult, inInclusiveRange(250, 320));
    expect(StepMath.kcal(10000, weightKg: 100), greaterThan(adult));
    expect(StepMath.kcal(10000, weightKg: 40), lessThan(adult));
    expect(StepMath.kcal(10000, weightKg: 5), adult); // implausible weight ignored
    expect(StepMath.kcal(0), 0);
  });
}
