/// Distance and calorie estimates, used ONLY when the health platform does
/// not supply its own values. Estimates, not measurements.
abstract final class StepMath {
  /// Average adult stride in metres when height is unknown.
  static const double defaultStrideM = 0.762;

  /// Used when weight is unknown (a typical adult; deliberately modest).
  static const double defaultWeightKg = 70;

  /// Net energy cost of walking, kcal per kg of body weight per km.
  static const double kcalPerKgPerKm = 0.53;

  /// Stride is about 0.415 x height (a standard approximation).
  static double strideMeters(double? heightCm) =>
      (heightCm != null && heightCm >= 50 && heightCm <= 260)
          ? heightCm * 0.415 / 100
          : defaultStrideM;

  static int distanceMeters(int steps, {double? heightCm}) =>
      (steps * strideMeters(heightCm)).round();

  static int kcal(int steps, {double? heightCm, double? weightKg}) {
    final kg = (weightKg != null && weightKg >= 20 && weightKg <= 400)
        ? weightKg
        : defaultWeightKg;
    final km = steps * strideMeters(heightCm) / 1000;
    return (km * kg * kcalPerKgPerKm).round();
  }
}
