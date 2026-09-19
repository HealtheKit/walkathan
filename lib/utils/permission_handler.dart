import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> requestActivityRecognitionPermission() async {
  // Check if permission is already granted
  if (await Permission.activityRecognition.isGranted) {
    debugPrint('Activity recognition permission granted');
    return;
  }

  // Request the permission
  final status = await Permission.activityRecognition.request();

  // Handle the status
  if (status.isGranted) {
    debugPrint('Permission granted');
  } else if (status.isDenied) {
    debugPrint('Permission denied');
  } else if (status.isPermanentlyDenied) {
    debugPrint('Permission permanently denied. Open app settings to enable it.');
    await openAppSettings(); // Directs the user to app settings
  }
}

Future<void> requestBodySensorsPermission() async {
  if (await Permission.sensors.isGranted) return;

  final status = await Permission.sensors.request();

  if (status.isPermanentlyDenied) {
    await openAppSettings();
  }
}
