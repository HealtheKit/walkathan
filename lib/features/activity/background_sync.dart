import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

import '../../config/supabase_config.dart';
import '../../repositories/step_repository.dart';
import 'count_from.dart';
import 'health_step_source.dart';
import 'sensor_step_source.dart';
import 'step_providers.dart' show loadDeviceId;
import 'step_queue.dart';
import 'step_sync_service.dart';

const String kStepSyncUniqueName = 'walkathon.stepSync.periodic';
const String kStepSyncTask = 'walkathon.stepSync';

/// Entry point the OS wakes up (about every 15 minutes at best; Android
/// decides, and battery savers may delay it). It runs in its own isolate with
/// no UI, so it rebuilds only what it needs.
///
/// It starts no GPS of its own: it reads the step counter / Health Connect
/// totals, removes the stationary periods the app's GPS tracker recorded,
/// and uploads day totals.
@pragma('vm:entry-point')
void stepSyncDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      try {
        await Supabase.initialize(url: supabaseUrl, publishableKey: supabaseAnonKey);
      } catch (_) {
        // Already initialised in this isolate: fine.
      }
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return true; // signed out: nothing to do

      final prefs = await SharedPreferences.getInstance();
      final profileId = prefs.getString('bg_profile_${user.id}');
      if (profileId == null) return true; // app has not synced yet

      double? h, w;
      try {
        final body = jsonDecode(prefs.getString('bg_body_$profileId') ?? '{}') as Map;
        h = (body['h'] as num?)?.toDouble();
        w = (body['w'] as num?)?.toDouble();
      } catch (_) {}

      // Learn of a count reset even if the app has not been opened since.
      try {
        await saveCountFrom(prefs, profileId, await StepRepository().fetchCountFrom(profileId));
      } catch (_) {}

      final service = StepSyncService(
        sources: [
          HealthStepSource(countFrom: () => loadCountFrom(profileId, prefs)),
          SensorStepSource(
              profileId: profileId, countFrom: () => loadCountFrom(profileId, prefs)),
        ],
        queue: StepQueue(prefs, profileId),
        uploader: StepRepository(),
        profileId: profileId,
        deviceId: await loadDeviceId(prefs),
        heightCm: h,
        weightKg: w,
      );
      final result = await service.sync(backfillDays: 1);
      // Offline: the totals are queued; report success so WorkManager does
      // not hammer the network. The next periodic run uploads them.
      return result.error == null || result.pending > 0;
    } catch (e) {
      debugPrint('Background step sync failed');
      return false; // ask WorkManager to retry with backoff
    }
  });
}

/// Registers the periodic task (Android only). iOS relies on HealthKit
/// history plus a sync whenever the app opens.
Future<void> registerStepSyncBackground() async {
  if (kIsWeb || !Platform.isAndroid) return;
  try {
    await Workmanager().initialize(stepSyncDispatcher);
    await Workmanager().registerPeriodicTask(
      kStepSyncUniqueName,
      kStepSyncTask,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  } catch (e) {
    debugPrint('Could not register background step sync: $e');
  }
}

Future<void> cancelStepSyncBackground() async {
  if (kIsWeb || !Platform.isAndroid) return;
  try {
    await Workmanager().cancelByUniqueName(kStepSyncUniqueName);
  } catch (_) {}
}
