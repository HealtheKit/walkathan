import 'step_day.dart';

enum SourceAvailability {
  /// Ready to read.
  available,

  /// Needs the user to grant activity / health permission.
  needsPermission,

  /// Android only: Health Connect is missing or needs an update.
  needsHealthConnect,

  /// This platform/device cannot provide the data (e.g. no step sensor).
  unsupported,
}

/// One place steps can be read from. Implementations are thin wrappers over
/// platform plugins so the sync logic can be tested with fakes.
abstract class StepSource {
  StepSourceKind get kind;

  Future<SourceAvailability> availability();

  /// Asks the OS for permission. Returns whether it is now granted.
  Future<bool> requestPermission();

  /// Day totals for the given local days. Days with no data are omitted.
  /// Manually entered steps must NOT be included.
  Future<List<StepDay>> readDays(List<DateTime> days, {required DateTime now});
}
