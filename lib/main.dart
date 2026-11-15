import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config/router/router_provider.dart';
import 'config/supabase_config.dart';
import 'features/activity/background_sync.dart';
import 'theme/app_theme.dart';
import 'theme/palette_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  await Supabase.initialize(
    url: supabaseUrl,
    publishableKey: supabaseAnonKey,
  );

  // Background step sync (Android only; no-op elsewhere).
  await registerStepSyncBackground();

  FlutterError.onError = (details) {
    debugPrint('FlutterError: ${details.exceptionAsString()}');
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('PlatformDispatcher error: $error');
    return true;
  };

  runApp(
    const ProviderScope(
      retry: _retry,
      child: MyApp(),
    ),
  );
}

/// At most two quick retries, so a failed load shows its error (with a
/// "Try again" button) within about a second instead of retrying for ~40 s.
Duration? _retry(int retryCount, Object error) =>
    retryCount < 2 ? Duration(milliseconds: 300 * (retryCount + 1)) : null;

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final palette = ref.watch(paletteProvider);

    return MaterialApp.router(
      title: 'Tresundios - TEF Walkathon',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(palette),
      darkTheme: AppTheme.dark(palette),
      themeMode: ThemeMode.system,
      routerConfig: router,
    );
  }
}
