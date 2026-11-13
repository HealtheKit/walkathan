import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_spacing.dart';

abstract final class AppTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  /// Large numerals (step counts, ranks) use tabular figures so digits
  /// don't shift width as values change.
  static const List<FontFeature> tabularFigures = [
    FontFeature.tabularFigures(),
  ];

  static ThemeData _build(Brightness brightness) {
    final scheme = AppColors.scheme(brightness);
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
    );

    final textTheme = _textTheme(base.textTheme, scheme);
    final fieldShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppSpacing.radiusField),
    );
    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppSpacing.radiusCard),
      side: BorderSide(color: scheme.outlineVariant),
    );

    OutlineInputBorder inputBorder(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusField),
          borderSide: BorderSide(color: color, width: width),
        );

    return base.copyWith(
      textTheme: textTheme,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      extensions: [
        brightness == Brightness.light ? BrandColors.light : BrandColors.dark,
      ],
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
        shape: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: cardShape,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 52),
          shape: fieldShape,
          textStyle: textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 52),
          shape: fieldShape,
          side: BorderSide(color: scheme.outlineVariant),
          textStyle: textTheme.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: fieldShape,
          textStyle: textTheme.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: inputBorder(scheme.outlineVariant),
        enabledBorder: inputBorder(scheme.outlineVariant),
        focusedBorder: inputBorder(scheme.primary, 2),
        errorBorder: inputBorder(scheme.error),
        focusedErrorBorder: inputBorder(scheme.error, 2),
        disabledBorder: inputBorder(scheme.outlineVariant.withValues(alpha: .5)),
        labelStyle: textTheme.bodyLarge
            ?.copyWith(color: scheme.onSurfaceVariant),
        floatingLabelStyle: textTheme.bodyMedium
            ?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600),
        hintStyle: textTheme.bodyLarge
            ?.copyWith(color: scheme.onSurfaceVariant.withValues(alpha: .7)),
        errorStyle: textTheme.bodySmall?.copyWith(color: scheme.error),
        prefixIconColor: scheme.onSurfaceVariant,
        suffixIconColor: scheme.onSurfaceVariant,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSheet),
        ),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle:
            textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle:
            textTheme.bodyMedium?.copyWith(color: scheme.onInverseSurface),
        actionTextColor: scheme.inversePrimary,
        shape: fieldShape,
        insetPadding: const EdgeInsets.all(16),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 68,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => textTheme.labelMedium?.copyWith(
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.primaryContainer,
        selectedLabelTextStyle:
            textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
        unselectedLabelTextStyle: textTheme.labelMedium,
        labelType: NavigationRailLabelType.all,
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        minVerticalPadding: 12,
        shape: fieldShape,
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outlineVariant),
        labelStyle: textTheme.labelLarge,
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          minimumSize: const Size(64, 44),
          shape: fieldShape,
          side: BorderSide(color: scheme.outlineVariant),
          textStyle: textTheme.labelLarge,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: cardShape,
        textStyle: textTheme.bodyLarge,
      ),
    );
  }

  static TextTheme _textTheme(TextTheme base, ColorScheme scheme) {
    TextStyle s(
      TextStyle? style,
      double size,
      FontWeight weight, {
      double height = 1.35,
      double spacing = 0,
    }) =>
        (style ?? const TextStyle()).copyWith(
          fontSize: size,
          fontWeight: weight,
          height: height,
          letterSpacing: spacing,
          color: scheme.onSurface,
        );

    return base.copyWith(
      displayLarge: s(base.displayLarge, 56, FontWeight.w800,
          height: 1.05, spacing: -1.5),
      displayMedium: s(base.displayMedium, 44, FontWeight.w800,
          height: 1.05, spacing: -1),
      displaySmall: s(base.displaySmall, 36, FontWeight.w700,
          height: 1.1, spacing: -0.5),
      headlineLarge: s(base.headlineLarge, 32, FontWeight.w700,
          height: 1.15, spacing: -0.5),
      headlineMedium: s(base.headlineMedium, 28, FontWeight.w700,
          height: 1.2, spacing: -0.3),
      headlineSmall: s(base.headlineSmall, 24, FontWeight.w700,
          height: 1.25, spacing: -0.2),
      titleLarge: s(base.titleLarge, 20, FontWeight.w700, spacing: -0.1),
      titleMedium: s(base.titleMedium, 16, FontWeight.w600),
      titleSmall: s(base.titleSmall, 14, FontWeight.w600),
      bodyLarge: s(base.bodyLarge, 16, FontWeight.w400, height: 1.5),
      bodyMedium: s(base.bodyMedium, 14, FontWeight.w400, height: 1.45),
      bodySmall: s(base.bodySmall, 12, FontWeight.w400, height: 1.4),
      labelLarge: s(base.labelLarge, 15, FontWeight.w600, spacing: 0.1),
      labelMedium: s(base.labelMedium, 12, FontWeight.w600, spacing: 0.2),
      labelSmall: s(base.labelSmall, 11, FontWeight.w600, spacing: 0.3),
    );
  }
}
