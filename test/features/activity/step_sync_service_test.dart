import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:walkathan/features/activity/step_day.dart';
import 'package:walkathan/features/activity/step_queue.dart';
import 'package:walkathan/features/activity/step_source.dart';
import 'package:walkathan/features/activity/step_sync_service.dart';

class FakeSource implements StepSource {
  FakeSource(this.kind, this.avail, this.data, {this.throwOnRead = false});
  @override
  final StepSourceKind kind;
  SourceAvailability avail;
  final Map<String, int> data; // dateKey -> steps
  final bool throwOnRead;

  @override
  Future<SourceAvailability> availability() async => avail;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<List<StepDay>> readDays(List<DateTime> days, {required DateTime now}) async {
    if (throwOnRead) throw StateError('boom');
    return [
      for (final d in days)
        if (data.containsKey(_k(d)))
          StepDay.forDate(d, source: kind, steps: data[_k(d)]!),
    ];
  }

  static String _k(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class FakeUploader implements StepUploader {
  final List<List<StepDay>> batches = [];
  bool offline = false;
  String? rejectDate;
  @override
  Future<List<IngestResult>> ingest({
    required String profileId,
    required String deviceId,
    required List<StepDay> days,
  }) async {
    if (offline) throw Exception('no network');
    batches.add(days);
    return [
      for (final d in days)
        d.localDate == rejectDate
            ? IngestResult(localDate: d.localDate, ok: false, reason: 'too_old')
            : IngestResult(localDate: d.localDate, ok: true),
    ];
  }
}

void main() {
  final now = DateTime(2026, 11, 13, 15);
  late StepQueue queue;
  late FakeUploader uploader;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    queue = StepQueue(await SharedPreferences.getInstance(), 'p1');
    uploader = FakeUploader();
  });

  StepSyncService svc(List<StepSource> s, {double? h, double? w}) => StepSyncService(
        sources: s, queue: queue, uploader: uploader,
        profileId: 'p1', deviceId: 'device-1234', heightCm: h, weightKg: w,
        clock: () => now);

  test('reads, estimates missing metrics, uploads and empties the queue', () async {
    final r = await svc([
      FakeSource(StepSourceKind.healthStore, SourceAvailability.available,
          {'2026-11-13': 8000, '2026-11-12': 6000}),
    ], h: 170, w: 65).sync();

    expect(r.today!.steps, 8000);
    expect(r.today!.distanceM, greaterThan(0)); // estimated
    expect(r.today!.kcal, greaterThan(0));
    expect(r.uploaded, 2);
    expect(r.pending, 0);
    expect(r.error, isNull);
    expect(uploader.batches.single.length, 2);
  });

  test('health store wins over a higher raw sensor total, and the sensor '
      'total is neither shown nor uploaded for that day', () async {
    final r = await svc([
      FakeSource(StepSourceKind.healthStore, SourceAvailability.available, {'2026-11-13': 5000}),
      FakeSource(StepSourceKind.phoneSensor, SourceAvailability.available, {'2026-11-13': 9200}),
    ]).sync();
    expect(r.today!.steps, 5000);
    expect(r.today!.source, StepSourceKind.healthStore);
    final uploaded = uploader.batches.expand((b) => b).toList();
    expect(uploaded.where((d) => d.source == StepSourceKind.phoneSensor), isEmpty,
        reason: 'the raw sensor cannot see cycling sessions');
  });

  test('sensor days are used only where the health store has no data', () async {
    final r = await svc([
      FakeSource(StepSourceKind.healthStore, SourceAvailability.available, {'2026-11-13': 5000}),
      FakeSource(StepSourceKind.phoneSensor, SourceAvailability.available,
          {'2026-11-13': 9200, '2026-11-12': 4100}),
    ]).sync();
    final uploaded = uploader.batches.expand((b) => b).toList();
    expect(uploaded.where((d) => d.localDate == '2026-11-12').single.source,
        StepSourceKind.phoneSensor);
    expect(uploaded.where((d) => d.localDate == '2026-11-13').single.source,
        StepSourceKind.healthStore);
    expect(r.today!.steps, 5000);
  });

  test('offline: nothing is lost, everything stays queued', () async {
    uploader.offline = true;
    final r = await svc([
      FakeSource(StepSourceKind.healthStore, SourceAvailability.available, {'2026-11-13': 3000}),
    ]).sync();
    expect(r.error, isNotNull);
    expect(r.pending, 1);
    expect(r.uploaded, 0);
    expect(r.today!.steps, 3000); // still shown locally

    // back online: the queued total uploads on the next run
    uploader.offline = false;
    final r2 = await svc([
      FakeSource(StepSourceKind.healthStore, SourceAvailability.available, {'2026-11-13': 3500}),
    ]).sync();
    expect(r2.pending, 0);
    expect(uploader.batches.last.single.steps, 3500); // raised, not duplicated
  });

  test('server rejections are final: reported, removed, not retried forever', () async {
    uploader.rejectDate = '2026-11-12';
    final r = await svc([
      FakeSource(StepSourceKind.healthStore, SourceAvailability.available,
          {'2026-11-13': 100, '2026-11-12': 100}),
    ]).sync();
    expect(r.rejected, ['too_old']);
    expect(r.pending, 0);
  });

  test('unavailable sources are skipped and their status is reported', () async {
    final r = await svc([
      FakeSource(StepSourceKind.healthStore, SourceAvailability.needsPermission, {'2026-11-13': 999}),
      FakeSource(StepSourceKind.phoneSensor, SourceAvailability.unsupported, {}),
    ]).sync();
    expect(r.today, isNull);
    expect(r.sourceStatus[StepSourceKind.healthStore], SourceAvailability.needsPermission);
    expect(r.sourceStatus[StepSourceKind.phoneSensor], SourceAvailability.unsupported);
    expect(uploader.batches, isEmpty);
  });

  test('one failing source does not stop the others', () async {
    final r = await svc([
      FakeSource(StepSourceKind.healthStore, SourceAvailability.available, {}, throwOnRead: true),
      FakeSource(StepSourceKind.phoneSensor, SourceAvailability.available, {'2026-11-13': 1234}),
    ]).sync();
    expect(r.today!.steps, 1234);
  });

  test('with health data for every day, only 31 entries upload in one batch', () async {
    String k(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final big = {
      for (var i = 0; i <= 30; i++) k(DateTime(2026, 11, 13 - i)): 1000 + i,
    };
    final s1 = FakeSource(StepSourceKind.healthStore, SourceAvailability.available, big);
    final s2 = FakeSource(StepSourceKind.phoneSensor, SourceAvailability.available, big);
    final r = await svc([s1, s2]).sync(backfillDays: 30);

    expect(r.uploaded, 31, reason: 'health store covers every day; sensor skipped');
    expect(uploader.batches.length, 1);
    expect(r.pending, 0);
  });
}
