import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:walkathan/theme/app_colors.dart';
import 'package:walkathan/theme/app_theme.dart';
import 'package:walkathan/theme/palette_provider.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

void main() {
  test('Kuwait theme uses its own colours in light and dark', () {
    final l = AppTheme.light(AppPalette.kuwait);
    final d = AppTheme.dark(AppPalette.kuwait);
    expect(l.colorScheme.primary, const Color(0xFF007A3D));
    expect(l.colorScheme.surface, const Color(0xFFF7F1E5));
    expect(d.colorScheme.surface, const Color(0xFF14110D));
    expect(l.extension<BrandColors>()!.success, isNot(l.colorScheme.primary),
        reason: 'goal-met must differ from ordinary progress');
    expect(AppTheme.light().colorScheme.primary, AppColors.cobalt, reason: 'TEF stays default');
  });

  test('Kuwait theme meets contrast targets', () {
    for (final t in [AppTheme.light(AppPalette.kuwait), AppTheme.dark(AppPalette.kuwait)]) {
      final c = t.colorScheme;
      expect(_contrast(c.onSurface, c.surface), greaterThan(7));
      expect(_contrast(c.onSurfaceVariant, c.surface), greaterThan(4.5));
      expect(_contrast(c.onPrimary, c.primary), greaterThan(4.5));
      expect(_contrast(c.primary, c.surface), greaterThan(4.5));
      expect(_contrast(c.error, c.surface), greaterThan(4.5));
    }
    final s = AppTheme.light(AppPalette.kuwait).extension<BrandColors>()!.success;
    expect(_contrast(Colors.white, s), greaterThan(4.5));
  });

  test('choice is remembered on the phone', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(paletteProvider), AppPalette.tef);
    await c.read(paletteProvider.notifier).select(AppPalette.kuwait);
    expect((await SharedPreferences.getInstance()).getString('app_palette'), 'kuwait');

    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    c2.read(paletteProvider);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(c2.read(paletteProvider), AppPalette.kuwait);
  });

  test('unknown stored value falls back to the default', () {
    expect(AppPalette.parse('nonsense'), AppPalette.tef);
    expect(AppPalette.parse(null), AppPalette.tef);
  });
}
