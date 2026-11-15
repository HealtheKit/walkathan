import 'package:flutter/material.dart';

/// Selectable colour themes.
enum AppPalette {
  /// From the TEF Kuwait logo: cobalt, vermilion, gold. The default.
  tef('TEF classic', 'Cobalt, gold and vermilion from the TEF logo'),

  /// Kuwait: flag green, Gulf turquoise, desert gold on warm sand.
  kuwait('Kuwait', 'Flag green, Gulf turquoise and desert gold');

  const AppPalette(this.label, this.description);
  final String label;
  final String description;

  static AppPalette parse(String? v) =>
      AppPalette.values.firstWhere((p) => p.name == v, orElse: () => AppPalette.tef);
}

/// Brand palette derived from the TEF Kuwait logo: cobalt, vermilion, gold.
abstract final class AppColors {
  static const Color cobalt = Color(0xFF0B57A8);
  static const Color vermilion = Color(0xFFC93F27);

  static ColorScheme scheme(Brightness brightness, [AppPalette palette = AppPalette.tef]) {
    if (palette == AppPalette.kuwait) return _kuwait(brightness);
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

/// Kuwait: flag green leads; Gulf turquoise as the second voice; desert
/// gold for highlights; warm sand surfaces (desert night in dark mode).
/// Flag red is kept for errors only, so it never reads as decoration.
ColorScheme _kuwait(Brightness brightness) {
  const green = Color(0xFF007A3D);
  const turquoise = Color(0xFF0F8B8D);
  const red = Color(0xFFB5121B);
  final base = ColorScheme.fromSeed(seedColor: green, brightness: brightness);
  if (brightness == Brightness.light) {
    return base.copyWith(
      primary: green,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFCDEBD8),
      onPrimaryContainer: const Color(0xFF00391C),
      secondary: turquoise,
      onSecondary: Colors.white,
      secondaryContainer: const Color(0xFFCFEDEC),
      onSecondaryContainer: const Color(0xFF003B3C),
      tertiary: const Color(0xFF8A6A0F),
      error: red,
      onError: Colors.white,
      errorContainer: const Color(0xFFFFDAD6),
      surface: const Color(0xFFF7F1E5),
      onSurface: const Color(0xFF1E1A14),
      onSurfaceVariant: const Color(0xFF5E5547),
      surfaceContainerLowest: const Color(0xFFFFFDF8),
      surfaceContainerLow: const Color(0xFFFFFBF2),
      surfaceContainer: const Color(0xFFF1E8D6),
      surfaceContainerHighest: const Color(0xFFE9DEC8),
      outline: const Color(0xFF8F8270),
      outlineVariant: const Color(0xFFE0D3BC),
    );
  }
  return base.copyWith(
    primary: const Color(0xFF6FD39A),
    onPrimary: const Color(0xFF00391C),
    primaryContainer: const Color(0xFF00532A),
    onPrimaryContainer: const Color(0xFFCDEBD8),
    secondary: const Color(0xFF6ED3D4),
    onSecondary: const Color(0xFF003738),
    secondaryContainer: const Color(0xFF004F50),
    tertiary: const Color(0xFFE6C35A),
    error: const Color(0xFFFF8A80),
    onError: const Color(0xFF5C0006),
    surface: const Color(0xFF14110D),
    onSurface: const Color(0xFFEDE4D3),
    onSurfaceVariant: const Color(0xFFB8AC97),
    surfaceContainerLowest: const Color(0xFF0E0C09),
    surfaceContainerLow: const Color(0xFF1B1712),
    surfaceContainer: const Color(0xFF221D17),
    surfaceContainerHighest: const Color(0xFF2E281F),
    outline: const Color(0xFF7D725F),
    outlineVariant: const Color(0xFF3A3328),
  );
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

  /// Kuwait: desert gold; goal-met is Gulf turquoise so it stays distinct
  /// from the green primary used for ordinary bars and progress.
  static const kuwaitLight = BrandColors(
    gold: Color(0xFFC9A227),
    silver: Color(0xFFB4B9C2),
    bronze: Color(0xFFB9784A),
    success: Color(0xFF0B7779),
    onMedal: Color(0xFF1B1405),
  );

  static const kuwaitDark = BrandColors(
    gold: Color(0xFFE6C35A),
    silver: Color(0xFF9AA1AD),
    bronze: Color(0xFFD39A6E),
    success: Color(0xFF6ED3D4),
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
