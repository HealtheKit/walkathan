import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pedometer/pedometer.dart';

/// The ONE connection to the phone's step sensors.
///
/// Why this exists: the pedometer plugin keeps a single native listener per
/// sensor. Opening a second Dart stream on the same sensor replaces that
/// listener, and closing the second stream unregisters the sensor for
/// everyone. The sync used to open (and close) its own stream every 20-30 s,
/// which silently switched the live counter off. Everything now goes
/// through this hub, which subscribes once and never cancels while the app
/// is running.
class StepCounterHub {
  StepCounterHub._();
  static final StepCounterHub instance = StepCounterHub._();

  // Android TYPE_STEP_DETECTOR: one event per step, within ~0.3 s of the
  // foot landing. Read directly so we get every step (the plugin's own
  // wrapper turns it into walking/stopped and drops the count).
  static const EventChannel _detectorChannel = EventChannel('step_detection');

  final StreamController<int> _counter = StreamController<int>.broadcast();
  final StreamController<void> _steps = StreamController<void>.broadcast();
  StreamSubscription<StepCount>? _counterSub;
  StreamSubscription<dynamic>? _detectorSub;

  int? _latest;
  Completer<int?>? _firstReading;

  /// Most recent cumulative counter value (steps since boot on Android).
  int? get latest => _latest;

  static bool get supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Cumulative counter readings (Android: steps since boot; iOS: steps the
  /// Motion coprocessor counted since boot). Updates every few steps.
  Stream<int> get counterStream {
    _ensureStarted();
    return _counter.stream;
  }

  /// One event per detected step (Android only; empty on iOS, whose
  /// pedometer already reports every ~2 s).
  Stream<void> get stepStream {
    _ensureStarted();
    return _steps.stream;
  }

  void _ensureStarted() {
    if (!supported) return;
    _counterSub ??= Pedometer.stepCountStream.listen(
      (e) {
        _latest = e.steps;
        _counter.add(e.steps);
        final f = _firstReading;
        if (f != null && !f.isCompleted) f.complete(e.steps);
      },
      onError: (Object e) {
        debugPrint('Step counter stream error: $e');
        _counter.addError(e);
        final f = _firstReading;
        if (f != null && !f.isCompleted) f.complete(null);
        // Typically "permission not granted yet". Allow a later retry.
        _counterSub?.cancel();
        _counterSub = null;
      },
    );
    if (Platform.isAndroid) {
      _detectorSub ??= _detectorChannel.receiveBroadcastStream().listen(
        (_) => _steps.add(null),
        onError: (Object e) {
          debugPrint('Step detector stream error: $e');
          _detectorSub?.cancel();
          _detectorSub = null;
        },
      );
    }
  }

  /// Current counter value for a sync. Uses the live value when one has
  /// arrived recently; otherwise waits briefly for the sensor's first report
  /// (Android sends the current value right after registering).
  Future<int?> read({Duration timeout = const Duration(seconds: 5)}) async {
    if (!supported) return null;
    _ensureStarted();
    // The sensor only reports on change, so the last value stays correct
    // however old it is: no event means no steps since.
    if (_latest != null) return _latest;
    _firstReading ??= Completer<int?>();
    try {
      return await _firstReading!.future.timeout(timeout, onTimeout: () => null);
    } finally {
      if (_firstReading?.isCompleted ?? true) _firstReading = null;
    }
  }

  /// After permission is granted, reconnect so readings start flowing.
  void restart() {
    _counterSub?.cancel();
    _counterSub = null;
    _detectorSub?.cancel();
    _detectorSub = null;
    _ensureStarted();
  }
}
