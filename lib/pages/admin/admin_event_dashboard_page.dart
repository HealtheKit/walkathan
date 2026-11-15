import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../models/custom_error.dart';
import '../../providers/profile_providers.dart';
import 'count_tools.dart';
import '../../repositories/admin_repository.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_theme.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/error_dialog.dart';
import '../../theme/app_colors.dart';
import '../widgets/app_shell.dart';
import '../widgets/infographics.dart';
import '../widgets/buttons.dart';
import '../widgets/state_widgets.dart';

final _num = NumberFormat.decimalPattern();
final _compact = NumberFormat.compact();
final _day = DateFormat.MMMd();

final eventOverviewProvider =
    FutureProvider.autoDispose.family<Map<String, dynamic>, String>(
  (ref, id) => ref.watch(adminRepositoryProvider).eventOverview(id),
);

/// Plain-word names for the server's quality flags.
const kFlagLabels = {
  'no_data': 'No step data',
  'dropout_risk': 'Dropout risk',
  'sync_stale': 'Not synced in 48 h',
  'high_values': 'Unusually high day',
  'low_consistency': 'Low consistency',
};

/// Participant rows as CSV (formula-safe), for reports.
String participantsCsv(String eventName, List<Map<String, dynamic>> rows) {
  String cell(Object? v) {
    final t = '${v ?? ''}';
    final safe = RegExp(r'^[=+\-@]').hasMatch(t) ? "'$t" : t;
    return '"${safe.replaceAll('"', '""')}"';
  }

  final b = StringBuffer()
    ..writeln('${cell('Event')},${cell(eventName)}')
    ..writeln()
    ..writeln(
        'rank,name,email,sex,status,total_steps,distance_km,active_days,active_pct,'
        'avg_daily,consistency,last_active,reward_eligible,reward,flags');
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    b.writeln([
      i + 1,
      cell(r['name']),
      cell(r['email']),
      cell(r['sex'] ?? ''),
      cell(r['status']),
      r['total_steps'] ?? 0,
      ((r['distance_m'] as num? ?? 0) / 1000).toStringAsFixed(1),
      r['active_days'] ?? 0,
      r['active_pct'] ?? 0,
      r['avg_daily'] ?? 0,
      r['consistency'] ?? 0,
      cell(r['last_active'] ?? ''),
      r['reward_eligible'] == true ? 'yes' : 'no',
      cell(r['reward'] ?? ''),
      cell(((r['flags'] as List?) ?? const []).join('; ')),
    ].join(','));
  }
  return b.toString();
}

/// Organizer view of one event: health, highlights, risks, data quality.
class AdminEventDashboardPage extends ConsumerStatefulWidget {
  const AdminEventDashboardPage({super.key, required this.event});
  final WalkEvent event;

  @override
  ConsumerState<AdminEventDashboardPage> createState() =>
      _AdminEventDashboardPageState();
}

class _AdminEventDashboardPageState
    extends ConsumerState<AdminEventDashboardPage> {
  String? _flag; // filter

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(eventOverviewProvider(widget.event.id));
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.event.name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (ref.watch(staffRoleProvider).value.canManage ||
              (ref.watch(isTransferReviewerProvider).value ?? false))
            PopupMenuButton<String>(
              tooltip: 'Count tools',
              icon: const Icon(Icons.rule_folder_outlined),
              onSelected: (v) async {
                final id = widget.event.id;
                switch (v) {
                  case 'verify':
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => VerifyCountsPage(
                            eventId: id, eventName: widget.event.name)));
                  case 'reset':
                    if (await confirmResetCounts(context, ref,
                        eventId: id, eventName: widget.event.name)) {
                      ref.invalidate(eventOverviewProvider(id));
                    }
                  case 'undo':
                    if (await confirmUndoReset(context, ref, eventId: id)) {
                      ref.invalidate(eventOverviewProvider(id));
                    }
                }
              },
              itemBuilder: (c) => const [
                PopupMenuItem(
                    value: 'verify', child: Text('Verify all counts')),
                PopupMenuItem(
                    value: 'reset', child: Text('Set ALL counts to zero…')),
                PopupMenuItem(
                    value: 'undo', child: Text('Undo reset for everyone')),
              ],
            ),
          IconButton(
            tooltip: 'Copy report as CSV',
            icon: const Icon(Icons.table_view_outlined),
            onPressed: data.value == null
                ? null
                : () async {
                    final rows = [
                      for (final r
                          in (data.value!['participants_detail'] as List))
                        Map<String, dynamic>.from(r as Map),
                    ];
                    await Clipboard.setData(ClipboardData(
                        text: participantsCsv(widget.event.name, rows)));
                    if (context.mounted) {
                      showAppSnackBar(context,
                          'Report copied. Paste it into a spreadsheet.');
                    }
                  },
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                ref.invalidate(eventOverviewProvider(widget.event.id)),
          ),
        ],
      ),
      body: data.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message:
              e is CustomError ? e.message : 'Could not load the dashboard.',
          onRetry: () => ref.invalidate(eventOverviewProvider(widget.event.id)),
        ),
        data: (o) {
          final people = [
            for (final r in (o['participants_detail'] as List))
              Map<String, dynamic>.from(r as Map),
          ];
          final active = people.where((p) => p['status'] == 'active').toList();
          final daily = [
            for (final d in (o['daily'] as List))
              Map<String, dynamic>.from(d as Map)
          ];
          List<Map<String, dynamic>> top(String key, {int n = 3}) {
            final l = [...active]..sort((a, b) =>
                ((b[key] as num?) ?? 0).compareTo((a[key] as num?) ?? 0));
            return l.where((p) => ((p[key] as num?) ?? 0) > 0).take(n).toList();
          }

          final flagged = active
              .where((p) => ((p['flags'] as List?) ?? const []).isNotEmpty)
              .toList();
          final shown = _flag == null
              ? active
              : active
                  .where((p) =>
                      ((p['flags'] as List?) ?? const []).contains(_flag))
                  .toList();
          final lastUpdate =
              DateTime.tryParse('${o['last_board_update'] ?? ''}')?.toLocal();

          Widget stat(String v, String l) => SizedBox(
                width: 150,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(v,
                          style: text.titleLarge?.copyWith(
                              fontFeatures: AppTheme.tabularFigures)),
                      Text(l,
                          style: text.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                    ]),
              );

          return RefreshIndicator(
            onRefresh: () async =>
                ref.invalidate(eventOverviewProvider(widget.event.id)),
            child: PageContainer(
              maxWidth: 1040,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: AppSpacing.pagePadding,
                children: [
                  Text('Status: ${o['event']['status']}',
                      style: text.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: AppSpacing.lg),
                  Wrap(
                      spacing: AppSpacing.lg,
                      runSpacing: AppSpacing.lg,
                      children: [
                        stat(_num.format(o['participants']), 'participants'),
                        stat(_num.format(o['active_participants']),
                            'have walked'),
                        stat(_num.format(o['active_today']), 'active today'),
                        stat(_compact.format(o['total_steps']), 'total steps'),
                        stat(
                            '${((o['total_distance_m'] as num) / 1000).toStringAsFixed(0)} km',
                            'total distance'),
                        stat('${o['synced_48h_pct']}%', 'synced in last 48 h'),
                        stat(_num.format(o['reward_eligible']),
                            'reward eligible'),
                        stat(
                            lastUpdate == null
                                ? '–'
                                : DateFormat.MMMd().add_Hm().format(lastUpdate),
                            'last board update'),
                      ]),
                  const SizedBox(height: AppSpacing.xl),
                  Text('Participation', style: text.titleMedium),
                  const SizedBox(height: AppSpacing.sm),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: DonutChart(
                        segments: [
                          DonutSegment((o['active_today'] as num).toDouble(),
                              context.brand.success, 'Walked today'),
                          DonutSegment(
                              ((o['active_participants'] as num) -
                                      (o['active_today'] as num))
                                  .toDouble()
                                  .clamp(0, double.infinity),
                              scheme.primary,
                              'Walked before, not today'),
                          DonutSegment(
                              ((o['participants'] as num) -
                                      (o['active_participants'] as num))
                                  .toDouble()
                                  .clamp(0, double.infinity),
                              scheme.outlineVariant,
                              'Not started'),
                        ],
                        center: Text('${o['participants']}',
                            style: text.titleLarge),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  Text('Daily participation', style: text.titleMedium),
                  const SizedBox(height: AppSpacing.sm),
                  _DailyBars(
                      daily: daily, max: (o['participants'] as num).toInt()),
                  const SizedBox(height: AppSpacing.xl),
                  Text('Highlights', style: text.titleMedium),
                  const SizedBox(height: AppSpacing.sm),
                  Card(
                    child: Column(children: [
                      _Highlight('Top walkers', top('total_steps'),
                          (p) => '${_num.format(p['total_steps'])} steps'),
                      const Divider(),
                      _Highlight('Most consistent', top('consistency'),
                          (p) => '${p['consistency']} / 100'),
                      const Divider(),
                      _Highlight('Most improved (7 days)', top('improvement'),
                          (p) => '+${_num.format(p['improvement'])}'),
                    ]),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  Text('Needs attention (${flagged.length})',
                      style: text.titleMedium),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: [
                        ChoiceChip(
                            label: Text('Everyone (${active.length})'),
                            selected: _flag == null,
                            onSelected: (_) => setState(() => _flag = null)),
                        for (final f in kFlagLabels.entries)
                          ChoiceChip(
                            label: Text(
                                '${f.value} (${active.where((p) => ((p['flags'] as List?) ?? const []).contains(f.key)).length})'),
                            selected: _flag == f.key,
                            onSelected: (_) => setState(() => _flag = f.key),
                          ),
                      ]),
                  const SizedBox(height: AppSpacing.md),
                  if (shown.isEmpty)
                    const EmptyState(
                        icon: Icons.check_circle_outline, title: 'Nothing here')
                  else
                    Card(
                      child: Column(children: [
                        for (final p in shown)
                          ListTile(
                            title: Text('${p['name']}',
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text([
                              '${_num.format(p['total_steps'])} steps',
                              '${p['active_pct']}% active',
                              'consistency ${p['consistency']}',
                              for (final f
                                  in ((p['flags'] as List?) ?? const []))
                                kFlagLabels[f] ?? '$f',
                            ].join(' · ')),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () async {
                              await Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) => AdminParticipantPage(
                                          event: widget.event,
                                          participant: p)));
                              ref.invalidate(
                                  eventOverviewProvider(widget.event.id));
                            },
                          ),
                      ]),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Highlight extends StatelessWidget {
  const _Highlight(this.title, this.people, this.value);
  final String title;
  final List<Map<String, dynamic>> people;
  final String Function(Map<String, dynamic>) value;

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(title),
        subtitle: Text(people.isEmpty
            ? 'No data yet'
            : people.map((p) => '${p['name']} (${value(p)})').join(', ')),
      );
}

class _DailyBars extends StatelessWidget {
  const _DailyBars({required this.daily, required this.max});
  final List<Map<String, dynamic>> daily;
  final int max;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    if (daily.isEmpty) {
      return Text('The event has not started yet.',
          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant));
    }
    final m = max <= 0 ? 1 : max;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Semantics(
            label: 'Active participants per day over ${daily.length} days',
            excludeSemantics: true,
            child: SizedBox(
              height: 110,
              child: GrowIn(
                  builder: (c, t) => Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            for (final d in daily)
                              Expanded(
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: daily.length > 20 ? 1 : 3),
                                  child: Container(
                                    height: (110 *
                                            t *
                                            ((d['active'] as num).toInt()) /
                                            m)
                                        .clamp(2, 110)
                                        .toDouble(),
                                    decoration: BoxDecoration(
                                        color: scheme.primary,
                                        borderRadius:
                                            const BorderRadius.vertical(
                                                top: Radius.circular(3))),
                                  ),
                                ),
                              ),
                          ])),
            ),
          ),
          const SizedBox(height: 4),
          Row(children: [
            Text(_day.format(DateTime.parse('${daily.first['date']}')),
                style: text.labelSmall),
            const Spacer(),
            Text(_day.format(DateTime.parse('${daily.last['date']}')),
                style: text.labelSmall),
          ]),
          Text('Active walkers per day', style: text.labelSmall),
        ]),
      ),
    );
  }
}

/// One participant: metrics, step history with audited corrections,
/// re-sync, sex, participation status and reward.
class AdminParticipantPage extends ConsumerStatefulWidget {
  const AdminParticipantPage(
      {super.key, required this.event, required this.participant});
  final WalkEvent event;
  final Map<String, dynamic> participant;

  @override
  ConsumerState<AdminParticipantPage> createState() =>
      _AdminParticipantPageState();
}

class _AdminParticipantPageState extends ConsumerState<AdminParticipantPage> {
  late Future<List<Map<String, dynamic>>> _days = _load();

  String get _pid => widget.participant['profile_id'] as String;
  String get _aid => widget.participant['account_id'] as String;
  Future<List<Map<String, dynamic>>> _load() =>
      ref.read(adminRepositoryProvider).participantDays(widget.event.id, _pid);

  Future<void> _run(
      Future<void> Function(AdminRepository r) f, String done) async {
    try {
      await f(ref.read(adminRepositoryProvider));
      if (!mounted) return;
      showAppSnackBar(context, done);
      setState(() {
        _days = _load();
      });
    } on CustomError catch (e) {
      if (mounted) errorDialog(context, e);
    }
  }

  bool get _canReset =>
      ref.read(staffRoleProvider).value.canManage ||
      (ref.read(isTransferReviewerProvider).value ?? false);

  Future<void> _reset() async {
    final done = await confirmResetCounts(context, ref,
        eventId: widget.event.id,
        eventName: widget.event.name,
        profileId: _pid,
        profileName: '${widget.participant['name']}');
    if (done && mounted) Navigator.pop(context); // the dashboard refreshes
  }

  Future<void> _undoReset() async {
    final done = await confirmUndoReset(context, ref,
        eventId: widget.event.id, profileId: _pid);
    if (done && mounted) Navigator.pop(context);
  }

  Future<String?> _text(String title, String label,
      {String? initial, bool number = false}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: number ? TextInputType.number : TextInputType.text,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(d, c.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
  }

  Future<void> _correct(Map<String, dynamic> day) async {
    final date = DateTime.parse('${day['date']}');
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.block),
              title: const Text('Exclude this day'),
              onTap: () => Navigator.pop(c, 'exclude')),
          ListTile(
              leading: const Icon(Icons.vertical_align_top),
              title: const Text('Cap this day'),
              onTap: () => Navigator.pop(c, 'cap')),
          if (day['correction'] != null)
            ListTile(
                leading: const Icon(Icons.undo),
                title: const Text('Remove correction'),
                onTap: () => Navigator.pop(c, 'clear')),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    int? cap;
    String? reason;
    if (action == 'cap') {
      cap = int.tryParse(
          await _text('Cap ${_day.format(date)}', 'Maximum steps') ?? '');
      if (cap == null) return;
    }
    if (action != 'clear') {
      reason = await _text('Reason (kept in the audit trail)', 'Reason');
      if (reason == null || reason.length < 3) return;
    }
    await _run(
        (r) => r.correctDay(_pid, date, action, cap: cap, reason: reason),
        'Saved');
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.participant;
    final role = ref.watch(staffRoleProvider).value;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
          title: Text('${p['name']}',
              maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: PageContainer(
        child: ListView(
          padding: AppSpacing.pagePadding,
          children: [
            Text(
                '${p['email']} · ${p['sex'] ?? 'sex not set'} · ${p['status']}',
                style:
                    text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: AppSpacing.md),
            Wrap(spacing: AppSpacing.xl, runSpacing: AppSpacing.md, children: [
              for (final (l, v) in [
                ('total steps', _num.format(p['total_steps'])),
                (
                  'active days',
                  '${p['active_days']} of ${p['event_days']} (${p['active_pct']}%)'
                ),
                ('daily average', _num.format(p['avg_daily'])),
                ('consistency', '${p['consistency']} / 100'),
                ('last active', '${p['last_active'] ?? '–'}'),
                (
                  'reward',
                  '${p['reward'] ?? (p['reward_eligible'] == true ? 'eligible' : '–')}'
                ),
              ])
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(v, style: text.titleMedium),
                  Text(l,
                      style: text.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ]),
            ]),
            const SizedBox(height: AppSpacing.xl),
            if (p['reset_on'] != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Text(
                    'Counts were set to zero on ${p['reset_on']}. Only steps from then on count.',
                    style: text.bodyMedium?.copyWith(color: scheme.error)),
              ),
            Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: [
              if (_canReset)
                OutlinedButton.icon(
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Set to zero'),
                  onPressed: _reset,
                ),
              if (_canReset && p['reset_on'] != null)
                OutlinedButton.icon(
                  icon: const Icon(Icons.undo),
                  label: const Text('Undo reset'),
                  onPressed: _undoReset,
                ),
              if (role.canVerify)
                OutlinedButton.icon(
                  icon: const Icon(Icons.sync),
                  label: const Text('Request re-sync'),
                  onPressed: () => _run((r) => r.requestResync(_pid),
                      'Their phone will upload its history again on next sync.'),
                ),
              if (role.canManage) ...[
                OutlinedButton.icon(
                  icon: const Icon(Icons.wc_outlined),
                  label: const Text('Set sex'),
                  onPressed: () async {
                    final sex = await showModalBottomSheet<String>(
                      context: context,
                      builder: (c) => SafeArea(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                        for (final s in const ['female', 'male', 'other'])
                          ListTile(
                              title: Text(s), onTap: () => Navigator.pop(c, s)),
                      ])),
                    );
                    if (sex != null) {
                      await _run((r) => r.setProfileSex(_pid, sex), 'Saved');
                    }
                  },
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.workspace_premium_outlined),
                  label: const Text('Set reward'),
                  onPressed: () async {
                    final award =
                        await _text('Reward', 'Award (e.g. Gold medal)');
                    if (award == null || award.length < 2 || !context.mounted) {
                      return;
                    }
                    final status = await showModalBottomSheet<String>(
                      context: context,
                      builder: (c) => SafeArea(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                        for (final s in const [
                          'selected',
                          'awarded',
                          'delivered'
                        ])
                          ListTile(
                              title: Text(s), onTap: () => Navigator.pop(c, s)),
                      ])),
                    );
                    if (status != null) {
                      await _run(
                          (r) =>
                              r.setReward(widget.event.id, _pid, award, status),
                          'Reward saved');
                    }
                  },
                ),
                OutlinedButton.icon(
                  icon:
                      Icon(p['status'] == 'active' ? Icons.block : Icons.undo),
                  label: Text(p['status'] == 'active'
                      ? 'Block from event'
                      : 'Reinstate'),
                  onPressed: () => _run(
                      (r) => r.setParticipantStatus(widget.event.id, _aid,
                          p['status'] == 'active' ? 'blocked' : 'active'),
                      'Updated'),
                ),
              ],
            ]),
            const SizedBox(height: AppSpacing.xl),
            Text('Step history', style: text.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: _days,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const LoadingState();
                }
                if (snap.hasError) {
                  return ErrorState(
                      message: 'Could not load the history.',
                      onRetry: () => setState(() {
                            _days = _load();
                          }));
                }
                final days = snap.data!;
                if (days.isEmpty) {
                  return const EmptyState(
                      icon: Icons.sensors_off,
                      title: 'No step data in this event yet');
                }
                return Card(
                  child: Column(children: [
                    for (final d in days)
                      ListTile(
                        title: Text(
                            '${_day.format(DateTime.parse('${d['date']}'))} · '
                            '${_num.format(d['counted'] ?? d['raw_steps'])} counted'),
                        subtitle: Text([
                          'day total ${_num.format(d['raw_steps'])}',
                          'readings: ${[
                            for (final s
                                in ((d['sources'] as List?) ?? const []))
                              '${(s as Map)['source'] == 'health_store' ? 'Health app' : 'phone sensor'} '
                                  '${_num.format(s['steps'])}',
                          ].join(', ')}',
                          if (d['before_reset'] == true)
                            'BEFORE RESET: not counted',
                          if (d['correction'] == 'exclude')
                            'EXCLUDED: ${d['reason']}',
                          if (d['correction'] == 'cap')
                            'CAPPED at ${d['cap_steps']}: ${d['reason']}',
                        ].join('\n')),
                        isThreeLine: true,
                        trailing: role.canVerify
                            ? IconButton(
                                tooltip: 'Correct this day',
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () => _correct(d))
                            : null,
                      ),
                  ]),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Event lifecycle and rules.
class AdminEventSettingsPage extends ConsumerStatefulWidget {
  const AdminEventSettingsPage({super.key, required this.event});
  final WalkEvent event;

  @override
  ConsumerState<AdminEventSettingsPage> createState() =>
      _AdminEventSettingsPageState();
}

class _AdminEventSettingsPageState
    extends ConsumerState<AdminEventSettingsPage> {
  late final _name = TextEditingController(text: widget.event.name);
  late final _target =
      TextEditingController(text: '${widget.event.dailyTarget}');
  late final _cap =
      TextEditingController(text: widget.event.dailyCap?.toString() ?? '');
  late final _rewardSteps = TextEditingController(
      text: widget.event.rewardMinSteps?.toString() ?? '');
  late final _rewardPct = TextEditingController(
      text: widget.event.rewardMinActivePct?.toString() ?? '');
  late DateTimeRange _range =
      DateTimeRange(start: widget.event.startsOn, end: widget.event.endsOn);
  late String _status = widget.event.status;
  late bool _gender = widget.event.showGenderBoards;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_name, _target, _cap, _rewardSteps, _rewardPct]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final target = int.tryParse(_target.text.trim());
    final cap = int.tryParse(_cap.text.trim());
    if (target == null || target < 1000 || target > 100000) {
      showAppSnackBar(context, 'Daily target must be 1,000 to 100,000.',
          isError: true);
      return;
    }
    if (_cap.text.trim().isNotEmpty &&
        (cap == null || cap < 1000 || cap > 100000)) {
      showAppSnackBar(context, 'Daily cap must be 1,000 to 100,000, or empty.',
          isError: true);
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(adminRepositoryProvider).updateEvent(
            widget.event.id,
            name: _name.text.trim(),
            startsOn: _range.start,
            endsOn: _range.end,
            status: _status,
            dailyTarget: target,
            dailyCap: cap,
            clearCap: _cap.text.trim().isEmpty,
            rewardMinSteps: int.tryParse(_rewardSteps.text.trim()),
            rewardMinActivePct: int.tryParse(_rewardPct.text.trim()),
            showGenderBoards: _gender,
          );
      if (mounted) Navigator.of(context).pop(true);
    } on CustomError catch (e) {
      if (mounted) errorDialog(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    Widget h(String t) => Padding(
        padding:
            const EdgeInsets.only(top: AppSpacing.xl, bottom: AppSpacing.sm),
        child: Text(t, style: text.titleMedium));

    return Scaffold(
      appBar: AppBar(title: const Text('Event settings')),
      body: PageContainer(
        child: ListView(
          padding: AppSpacing.pagePadding,
          children: [
            h('Status'),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'draft', label: Text('Draft')),
                ButtonSegment(value: 'published', label: Text('Live')),
                ButtonSegment(value: 'paused', label: Text('Paused')),
                ButtonSegment(value: 'cancelled', label: Text('Cancelled')),
              ],
              selected: {_status},
              onSelectionChanged: (s) => setState(() => _status = s.first),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Draft events are hidden from participants. Paused events stay '
              'visible with a notice; steps are still saved.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            h('Details'),
            TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: AppSpacing.md),
            OutlinedButton.icon(
              icon: const Icon(Icons.date_range),
              label: Text(
                  '${_day.format(_range.start)} – ${_day.format(_range.end)}'),
              onPressed: () async {
                final r = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(DateTime.now().year - 1),
                    lastDate: DateTime(DateTime.now().year + 3),
                    initialDateRange: _range);
                if (r != null && r.duration.inDays <= 365) {
                  setState(() => _range = r);
                }
              },
            ),
            h('Scoring'),
            TextField(
                controller: _target,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Daily target (steps)')),
            const SizedBox(height: AppSpacing.md),
            TextField(
                controller: _cap,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Daily cap (optional)',
                    helperText: 'Steps above this per day do not count')),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _gender,
              onChanged: (v) => setState(() => _gender = v),
              title: const Text('Men\'s and women\'s boards'),
            ),
            h('Recognition'),
            TextField(
                controller: _rewardSteps,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Minimum total steps (optional)')),
            const SizedBox(height: AppSpacing.md),
            TextField(
                controller: _rewardPct,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Minimum active days, % (optional)')),
            const SizedBox(height: AppSpacing.xl),
            AppButton(label: 'Save', loading: _saving, onPressed: _save),
          ],
        ),
      ),
    );
  }
}

/// Super Admin: grant organizer, verifier or viewer roles by email.
class AdminStaffPage extends ConsumerStatefulWidget {
  const AdminStaffPage({super.key});

  @override
  ConsumerState<AdminStaffPage> createState() => _AdminStaffPageState();
}

class _AdminStaffPageState extends ConsumerState<AdminStaffPage> {
  late Future<List<({String email, String role})>> _staff =
      ref.read(adminRepositoryProvider).listStaff();
  final _email = TextEditingController();
  String _role = 'organizer';

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  void _reload() =>
      setState(() => _staff = ref.read(adminRepositoryProvider).listStaff());

  Future<void> _set(String email, String? role) async {
    try {
      final r = await ref.read(adminRepositoryProvider).setStaff(email, role);
      if (!mounted) return;
      showAppSnackBar(
          context,
          switch (r) {
            'ok' => 'Saved',
            'multiple_profiles' =>
              'An organizer login can have only one profile. This login has several.',
            _ => 'No account with that email. Add them as a member first.',
          },
          isError: r != 'ok');
      _reload();
    } on CustomError catch (e) {
      if (mounted) errorDialog(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Staff roles')),
      body: PageContainer(
        child: ListView(
          padding: AppSpacing.pagePadding,
          children: [
            Text(
              'Organizers manage events, participants, messages and rewards. '
              'Verifiers review and correct step data. Viewers can see '
              'dashboards and reports only.',
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Member email')),
            const SizedBox(height: AppSpacing.md),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'organizer', label: Text('Organizer')),
                ButtonSegment(value: 'verifier', label: Text('Verifier')),
                ButtonSegment(value: 'viewer', label: Text('Viewer')),
              ],
              selected: {_role},
              onSelectionChanged: (s) => setState(() => _role = s.first),
            ),
            const SizedBox(height: AppSpacing.md),
            AppButton(
                label: 'Grant role',
                onPressed: () => _set(_email.text.trim(), _role)),
            const SizedBox(height: AppSpacing.xl),
            FutureBuilder<List<({String email, String role})>>(
              future: _staff,
              builder: (c, s) {
                if (s.connectionState != ConnectionState.done) {
                  return const LoadingState();
                }
                if (s.hasError) {
                  return ErrorState(
                      message: 'Could not load staff.', onRetry: _reload);
                }
                if (s.data!.isEmpty) {
                  return const EmptyState(title: 'No staff yet');
                }
                return Card(
                  child: Column(children: [
                    for (final m in s.data!)
                      ListTile(
                        title: Text(m.email,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(m.role),
                        trailing: IconButton(
                            tooltip: 'Remove role',
                            icon: const Icon(Icons.person_remove_outlined),
                            onPressed: () => _set(m.email, null)),
                      ),
                  ]),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
