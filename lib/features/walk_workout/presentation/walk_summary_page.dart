import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../application/walk_session_controller.dart';
import '../domain/walk_math.dart';
import '../domain/walk_models.dart';
import 'walk_ui.dart';
import 'widgets/live_chart.dart';
import 'widgets/metric_card.dart';
import 'widgets/route_view.dart';
import 'widgets/walk_sheets.dart';

/// After Finish: every figure of the walk, then Save or Discard. The walk
/// stays "live" (banner visible) until one of the two is chosen.
class WalkSummaryPage extends ConsumerStatefulWidget {
  const WalkSummaryPage({super.key});

  @override
  ConsumerState<WalkSummaryPage> createState() => _WalkSummaryPageState();
}

class _WalkSummaryPageState extends ConsumerState<WalkSummaryPage> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  bool _seeded = false;
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  String _shareText(WorkoutSummary sum) {
    final s = sum.session;
    final u = s.settings.units;
    return '${_title.text.trim().isEmpty ? 'Walk' : _title.text.trim()}\n'
        '${paceService.distanceIn(u, s.distanceM).toStringAsFixed(2)} ${paceService.distanceUnit(u)} in '
        '${formatDuration(sum.active)}\n'
        'Pace ${paceService.formatPace(paceService.paceSeconds(u, sum.avgSpeed))} ${paceService.paceUnit(u)} · '
        '${s.steps} steps · ${s.kcal.round()} kcal';
  }

  Future<void> _copy(String what, String data) async {
    await Clipboard.setData(ClipboardData(text: data));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$what copied')));
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final nav = ref.read(walkNavProvider);
    await ref.read(walkSessionProvider.notifier).save(
        title: _title.text.trim().isEmpty ? 'Walk' : _title.text.trim(), note: _note.text.trim());
    if (!mounted) return;
    setState(() => _saving = false);
    if (ref.read(walkSessionProvider) == null) {
      ref.invalidate(walkHistoryProvider);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Walk saved')));
      nav.home(context);
    }
  }

  Future<void> _discard() async {
    if (!await confirmDiscard(context)) return;
    final nav = ref.read(walkNavProvider);
    await ref.read(walkSessionProvider.notifier).discard();
    if (mounted) nav.home(context);
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(walkSessionProvider);
    final nav = ref.read(walkNavProvider);

    return WalkTheme(
      child: Builder(builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        final text = Theme.of(context).textTheme;

        if (session == null) {
          return Scaffold(
            appBar: AppBar(leading: BackButton(onPressed: () => nav.home(context)), title: const Text('Walk')),
            body: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('Nothing to review', style: text.titleLarge),
                const SizedBox(height: 16),
                FilledButton(onPressed: () => nav.toSetup(context), child: const Text('Start another walk')),
              ]),
            ),
          );
        }
        if (!_seeded) {
          _seeded = true;
          _title.text = session.title == 'Walk'
              ? '${DateFormat.EEEE().format(session.startedAt)} walk'
              : session.title;
          _note.text = session.note;
        }

        final now = ref.read(walkClockProvider)();
        final sum = WorkoutSummary.of(session, now);
        final s = session;
        final u = s.settings.units;
        final profile = ref.read(walkUserProfileProvider);
        final zoneTotal = s.zoneMs.fold<int>(0, (a, b) => a + b);
        final df = DateFormat.yMMMEd().add_jm();

        String dist(double m) =>
            '${paceService.distanceIn(u, m).toStringAsFixed(2)} ${paceService.distanceUnit(u)}';
        String pace(double mps) => paceService.formatPace(paceService.paceSeconds(u, mps));

        final rows = <(String, String)>[
          ('Total time', formatDuration(sum.total)),
          ('Moving time', formatDuration(sum.active)),
          ('Paused time', formatDuration(sum.paused)),
          ('Average pace', '${pace(sum.avgSpeed)} ${paceService.paceUnit(u)}'),
          ('Best pace', '${pace(s.maxSpeed)} ${paceService.paceUnit(u)}'),
          ('Average speed', '${paceService.speedIn(u, sum.avgSpeed).toStringAsFixed(1)} ${paceService.speedUnit(u)}'),
          ('Maximum speed', '${paceService.speedIn(u, s.maxSpeed).toStringAsFixed(1)} ${paceService.speedUnit(u)}'),
          ('Average cadence', '${sum.avgCadence} steps/min'),
          ('Maximum cadence', '${s.maxCadence} steps/min'),
          ('Average heart rate', s.avgHr == null ? 'not measured' : '${s.avgHr} bpm'),
          ('Maximum heart rate', s.maxHr == 0 ? 'not measured' : '${s.maxHr} bpm (max for age ${profile.maxHeartRate})'),
          ('Elevation gain', s.altitude == null ? 'no data' : '${s.elevGain.round()} m'),
          ('Elevation loss', s.altitude == null ? 'no data' : '${s.elevLoss.round()} m'),
        ];

        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: const Text('Walk summary'),
            actions: [
              IconButton(
                  tooltip: 'Share as text',
                  icon: const Icon(Icons.ios_share),
                  onPressed: () => _copy('Summary', _shareText(sum))),
              PopupMenuButton<String>(
                tooltip: 'Export',
                icon: const Icon(Icons.file_download_outlined),
                onSelected: (v) => v == 'gpx'
                    ? _copy('GPX route', toGpx(s.copyWith(title: _title.text.trim())))
                    : _copy('JSON data', jsonEncode(s.toJson())),
                itemBuilder: (c) => [
                  PopupMenuItem(value: 'gpx', enabled: s.route.length >= 2, child: const Text('Copy route as GPX')),
                  const PopupMenuItem(value: 'json', child: Text('Copy data as JSON')),
                ],
              ),
            ],
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(children: [
                Expanded(
                  child: SizedBox(
                    height: 56,
                    child: OutlinedButton(
                      onPressed: _saving ? null : _discard,
                      style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
                      child: const Text('Discard'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 56,
                    child: FilledButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                          : const Text('Save workout', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ]),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Text(df.format(s.startedAt), style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              if (s.errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(s.errorMessage!, style: text.bodyMedium?.copyWith(color: scheme.error)),
                ),
              if (!s.goal.isOpen)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    Icon(sum.goalMet ? Icons.emoji_events : Icons.flag_outlined,
                        color: sum.goalMet ? scheme.tertiary : scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                          sum.goalMet
                              ? '${s.goal.type.label} goal reached'
                              : '${s.goal.type.label} goal: ${(s.goalProgress(now) * 100).round()}% done',
                          style: text.titleSmall),
                    ),
                  ]),
                ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                    child: MetricCard(
                        label: 'Distance',
                        value: paceService.distanceIn(u, s.distanceM).toStringAsFixed(2),
                        unit: paceService.distanceUnit(u),
                        large: true,
                        accent: scheme.primary)),
                const SizedBox(width: 10),
                Expanded(child: MetricCard(label: 'Moving time', value: formatCompact(sum.active), large: true)),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: MetricCard(label: 'Steps', value: '${s.steps}', icon: Icons.directions_walk)),
                const SizedBox(width: 10),
                Expanded(
                    child: MetricCard(
                        label: 'Calories',
                        value: '${s.kcal.round()}',
                        unit: 'kcal',
                        icon: Icons.local_fire_department_outlined)),
              ]),
              const SizedBox(height: 14),
              RouteView(points: s.route, gpsOn: s.settings.useGps, live: false),
              const SizedBox(height: 14),
              Container(
                decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(18)),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Column(children: [
                  for (final (label, value) in rows)
                    MergeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(children: [
                          Expanded(
                              child: Text(label,
                                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant))),
                          const SizedBox(width: 12),
                          Flexible(child: Text(value, style: text.bodyLarge, textAlign: TextAlign.end)),
                        ]),
                      ),
                    ),
                ]),
              ),
              if (zoneTotal > 0) ...[
                const SizedBox(height: 16),
                Text('Heart-rate zones', style: text.titleMedium),
                const SizedBox(height: 6),
                for (var i = 4; i >= 0; i--)
                  Semantics(
                    label: '${kHeartRateZones[i]} ${formatCompact(Duration(milliseconds: s.zoneMs[i]))}',
                    excludeSemantics: true,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(children: [
                        SizedBox(width: 76, child: Text(kHeartRateZones[i], style: text.bodySmall)),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              minHeight: 10,
                              value: s.zoneMs[i] / zoneTotal,
                              backgroundColor: scheme.surfaceContainerHighest,
                              color: Color.lerp(scheme.primary, scheme.error, i / 4),
                            ),
                          ),
                        ),
                        SizedBox(
                            width: 56,
                            child: Text(formatCompact(Duration(milliseconds: s.zoneMs[i])),
                                style: text.bodySmall, textAlign: TextAlign.end)),
                      ]),
                    ),
                  ),
              ],
              if (s.series.length >= 3) ...[
                const SizedBox(height: 16),
                LiveChart(series: s.series, units: u),
              ],
              if (s.splits.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Splits (per km)', style: text.titleMedium),
                for (final sp in s.splits)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(radius: 14, child: Text('${sp.index}', style: text.labelSmall)),
                    title: Text(formatCompact(Duration(milliseconds: sp.durationMs))),
                    trailing: sp.durationMs == sum.bestSplitMs && s.splits.length > 1
                        ? Chip(label: const Text('Best'), visualDensity: VisualDensity.compact)
                        : null,
                  ),
              ],
              if (s.laps.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Laps', style: text.titleMedium),
                for (final l in s.laps)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.flag_outlined),
                    title: Text('Lap ${l.index} · ${formatCompact(Duration(milliseconds: l.durationMs))}'),
                    subtitle: Text('${dist(l.distanceM)} · '
                        '${pace(l.durationMs <= 0 ? 0 : l.distanceM / (l.durationMs / 1000))} ${paceService.paceUnit(u)} · '
                        '${l.kcal.round()} kcal'),
                  ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _title,
                maxLength: 60,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              TextField(
                controller: _note,
                maxLength: 300,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
              ),
            ],
          ),
        );
      }),
    );
  }
}
