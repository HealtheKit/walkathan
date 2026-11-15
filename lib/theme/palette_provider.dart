import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_colors.dart';

/// The chosen colour theme, remembered on this phone.
class PaletteNotifier extends Notifier<AppPalette> {
  static const _key = 'app_palette';

  @override
  AppPalette build() {
    SharedPreferences.getInstance().then((p) {
      final saved = AppPalette.parse(p.getString(_key));
      if (saved != state) state = saved;
    }).catchError((_) {});
    return AppPalette.tef;
  }

  Future<void> select(AppPalette palette) async {
    state = palette;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, palette.name);
    } catch (_) {}
  }
}

final paletteProvider = NotifierProvider<PaletteNotifier, AppPalette>(PaletteNotifier.new);
