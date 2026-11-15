import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../../activity/step_counter_hub.dart';
import '../domain/walk_models.dart';
import '../domain/walk_services.dart';

// =====================================================================
// REAL sensors, built on what this app already ships (geolocator and the
// shared StepCounterHub). They are NOT switched on by default: see
// `walkUseDeviceSensorsProvider`. They compile and follow the interfaces,
// but have not been run on a phone yet, so try them on a device before
// relying on them.
// =====================================================================

/// GPS through geolocator. Keeps the newest fix and hands it out per tick.
class GeolocatorLocationService implements LocationService {
  StreamSubscription<Position>? _sub;
  LocationPoint? _latest;
  int _lastGivenMs = 0;

  static String _map(LocationPermission p) => switch (p) {
        LocationPermission.always || LocationPermission.whileInUse => 'granted',
        LocationPermission.deniedForever => 'deniedForever',
        _ => 'denied',
      };

  @override
  Future<String> permissionStatus() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return 'serviceOff';
      return _map(await Geolocator.checkPermission());
    } catch (_) {
      return 'denied';
    }
  }

  @override
  Future<String> requestPermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return 'serviceOff';
      return _map(await Geolocator.requestPermission());
    } catch (_) {
      return 'denied';
    }
  }

  @override
  Future<void> start() async {
    await _sub?.cancel();
    _latest = null;
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 0),
    ).listen(
      (p) => _latest = LocationPoint(
        lat: p.latitude,
        lon: p.longitude,
        tMs: DateTime.now().millisecondsSinceEpoch,
        altitude: p.altitude.isFinite ? p.altitude : null,
        accuracyM: p.accuracy,
      ),
      onError: (Object _) => _latest = null,
    );
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  @override
  LocationPoint? next(Duration dt) {
    final p = _latest;
    // The same fix twice means nothing new arrived: report "no fix".
    if (p == null || p.tMs == _lastGivenMs) return null;
    _lastGivenMs = p.tMs;
    return p;
  }
}

/// The phone's step counter, through the app's single sensor connection.
class HubStepCounterService implements StepCounterService {
  StreamSubscription<int>? _sub;
  int? _last;
  int _pending = 0;

  @override
  Future<bool> available() async => StepCounterHub.supported;

  @override
  Future<void> start() async {
    await _sub?.cancel();
    _last = null;
    _pending = 0;
    _sub = StepCounterHub.instance.counterStream.listen((c) {
      final prev = _last;
      _last = c;
      if (prev != null) _pending += c >= prev ? c - prev : c; // counter restarts on reboot
    }, onError: (Object _) {});
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  @override
  int next(Duration dt) {
    final n = _pending;
    _pending = 0;
    return n;
  }
}

/// No heart-rate source on a plain phone. INTEGRATION POINT: BLE strap or
/// watch companion.
class NoHeartRateService implements HeartRateService {
  @override
  Future<bool> available() async => false;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  int? next(Duration dt) => null;
}
