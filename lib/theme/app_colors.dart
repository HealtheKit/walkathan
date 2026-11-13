import 'package:flutter/material.dart';

/// Brand palette derived from the TEF Kuwait logo: cobalt, vermilion, gold.
abstract final class AppColors {
  static const Color cobalt = Color(0xFF0B57A8);
  static const Color vermilion = Color(0xFFC93F27);

  static ColorScheme scheme(Brightness brightness) {
    final base = ColorScheme.fromSeed(
      seedColor: cobalt,
      brightness: brightness,
    );
    if (brightness == Brightness.light) {
      return base.copyWith(
        primary: cobalt,
        onPrimary: Colors.white,
        error: const Color(0xFFB3321E),
        onError: Colors.white,
        surface: const Color(0xFFF7F7F5),
        onSurface: const Color(0xFF15181D),
        onSurfaceVariant: const Color(0xFF555B66),
        surfaceContainerLowest: Colors.white,
        surfaceContainerLow: const Color(0xFFFFFFFF),
        surfaceContainer: const Color(0xFFF0F0ED),
        surfaceContainerHighest: const Color(0xFFE9E9E5),
        outline: const Color(0xFF8A909B),
        outlineVariant: const Color(0xFFDADCE0),
      );
    }
    return base.copyWith(
      primary: const Color(0xFF8AB4F8),
      onPrimary: const Color(0xFF062B57),
      primaryContainer: const Color(0xFF0F3D7A),
      onPrimaryContainer: const Color(0xFFD6E4FF),
      error: const Color(0xFFFF8A75),
      onError: const Color(0xFF4A0E03),
      surface: const Color(0xFF0E1116),
      onSurface: const Color(0xFFE6E8EC),
      onSurfaceVariant: const Color(0xFFA6ACB7),
      surfaceContainerLowest: const Color(0xFF0A0C10),
      surfaceContainerLow: const Color(0xFF14181F),
      surfaceContainer: const Color(0xFF181D25),
      surfaceContainerHighest: const Color(0xFF232A35),
      outline: const Color(0xFF6B7280),
      outlineVariant: const Color(0xFF2B323D),
    );
  }
}

/// Semantic colors that Material's [ColorScheme] has no slot for.
@immutable
class BrandColors extends ThemeExtension<BrandColors> {
  const BrandColors({
    required this.gold,
    required this.silver,
    required this.bronze,
    required this.success,
    required this.onMedal,
  });

  final Color gold;
  final Color silver;
  final Color bronze;
  final Color success;

  /// Text/icon color that stays legible on gold/silver/bronze fills.
  final Color onMedal;

  static const light = BrandColors(
    gold: Color(0xFFD9A81E),
    silver: Color(0xFFB4B9C2),
    bronze: Color(0xFFC08457),
    success: Color(0xFF1E7B45),
    onMedal: Color(0xFF1B1405),
  );

  static const dark = BrandColors(
    gold: Color(0xFFE6B84A),
    silver: Color(0xFF9AA1AD),
    bronze: Color(0xFFD39A6E),
    success: Color(0xFF5CC98A),
    onMedal: Color(0xFF1B1405),
  );

  @override
  BrandColors copyWith({
    Color? gold,
    Color? silver,
    Color? bronze,
    Color? success,
    Color? onMedal,
  }) =>
      BrandColors(
        gold: gold ?? this.gold,
        silver: silver ?? this.silver,
        bronze: bronze ?? this.bronze,
        success: success ?? this.success,
        onMedal: onMedal ?? this.onMedal,
      );

  @override
  BrandColors lerp(ThemeExtension<BrandColors>? other, double t) {
    if (other is! BrandColors) return this;
    return BrandColors(
      gold: Color.lerp(gold, other.gold, t)!,
      silver: Color.lerp(silver, other.silver, t)!,
      bronze: Color.lerp(bronze, other.bronze, t)!,
      success: Color.lerp(success, other.success, t)!,
      onMedal: Color.lerp(onMedal, other.onMedal, t)!,
    );
  }
}

extension BrandColorsContext on BuildContext {
  BrandColors get brand => Theme.of(this).extension<BrandColors>()!;
}
