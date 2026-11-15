import '../../core/time/local_day.dart';
import 'step_day.dart';
import 'step_math.dart';
import 'step_queue.dart';
import 'step_source.dart';

class IngestResult {
  const IngestResult({required this.localDate, required this.ok, this.reason});
  final String localDate;
  final bool ok;
  final String? reason;
}

/// Uploads day totals. Implemented by the Supabase repository.
abstract class StepUploader {
  /// Results are in the same order as [days].
  Future<List<IngestResult>> ingest({
    required String profileId,
    required String deviceId,
    required List<StepDay> days,
  });
}

class SyncResult {
  const SyncResult({
    required this.today,
    required this.sourceStatus,
    required this.uploaded,
    required this.rejected,
    required this.pending,
    this.error,
  });

  /// Best view of today from this device's sources (null = no data yet).
  final StepDay? today;
  final Map<StepSourceKind, SourceAvailability> sourceStatus;
  final int uploaded;

  /// Reasons the server refused entries (final; not retried).
  final List<String> rejected;

  /// Entries still waiting to upload (offline or failed).
  final int pending;
  final String? error;
}

/// Reads every available source, queues the totals locally, then uploads.
/// Safe to run repeatedly and to be interrupted: the queue keeps the largest
/// total per day/source, and the server is idempotent.
class StepSyncService {
  StepSyncService({
    required this.sources,
    required this.queue,
    required this.uploader,
    required this.profileId,
    required this.deviceId,
    this.heightCm,
    this.weightKg,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final List<StepSource> sources;
  final StepQueue queue;
  final StepUploader uploader;
  final String profileId;
  final String deviceId;
  final double? heightCm;
  final double? weightKg;
  final DateTime Function() _clock;

  static const int batchSize = 40;

  Future<SyncResult> sync({int backfillDays = 3}) async {
    final now = _clock();
    final days = [for (var i = 0; i <= backfillDays; i++) daysAgo(now, i)];
    final status = <StepSourceKind, SourceAvailability>{};
    final todayReadings = <StepDay>[];
    final todayKey = dateKey(now);

    // Read everything first so the rule "health store beats the raw sensor"
    // can be applied per day before anything is queued.
    final readings = <StepDay>[];
    for (final source in sources) {
      final availability = await source.availability();
      status[source.kind] = availability;
      if (availability != SourceAvailability.available) continue;
      try {
        readings.addAll((await source.readDays(days, now: now)).map(_withEstimates));
      } catch (_) {
        // One failing source must not stop the others; its status shows in
        // the next refresh. Details are deliberately not logged (health data).
      }
    }

    // The phone sensor cannot tell cycling or exercise-machine steps from
    // walking. For any day the health store covers, its (cleaned) total is
    // the only one we keep and upload.
    final healthDays = {
      for (final r in readings)
        if (r.source == StepSourceKind.healthStore) r.localDate,
    };
    for (final r in readings) {
      if (r.source == StepSourceKind.phoneSensor && healthDays.contains(r.localDate)) {
        continue;
      }
      await queue.put(r, now: now);
      if (r.localDate == todayKey) todayReadings.add(r);
    }

    final upload = await _upload();
    return SyncResult(
      today: resolveDay(todayReadings),
      sourceStatus: status,
      uploaded: upload.uploaded,
      rejected: upload.rejected,
      pending: queue.pendingCount,
      error: upload.error,
    );
  }

  /// Fills distance/calories from the user's height and weight when the
  /// platform did not provide them.
  StepDay _withEstimates(StepDay d) => d.copyWith(
        distanceM: d.distanceM ?? StepMath.distanceMeters(d.steps, heightCm: heightCm),
        kcal: d.kcal ?? StepMath.kcal(d.steps, heightCm: heightCm, weightKg: weightKg),
      );

  Future<({int uploaded, List<String> rejected, String? error})> _upload() async {
    final pending = queue.pending();
    var uploaded = 0;
    final rejected = <String>[];
    for (var i = 0; i < pending.length; i += batchSize) {
      final chunk = pending.sublist(i, i + batchSize > pending.length ? pending.length : i + batchSize);
      try {
        final results = await uploader.ingest(
          profileId: profileId,
          deviceId: deviceId,
          days: chunk,
        );
        // A phone still waiting for approval must keep its steps queued.
        if (results.any((r) => r.reason == 'device_not_approved')) {
          return (
            uploaded: uploaded,
            rejected: rejected,
            error: 'This phone is waiting for approval.'
          );
        }
        // Accepted AND definitively rejected entries leave the queue.
        await queue.remove(chunk.map((d) => d.key));
        for (final r in results) {
          if (r.ok) {
            uploaded++;
          } else if (r.reason != null) {
            rejected.add(r.reason!);
          }
        }
      } catch (e) {
        // Offline or server error: keep everything queued for the next run.
        return (uploaded: uploaded, rejected: rejected, error: e.toString());
      }
    }
    return (uploaded: uploaded, rejected: rejected, error: null);
  }
}
