import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/activity/step_providers.dart';
import '../../models/custom_error.dart';
import '../../providers/profile_providers.dart';
import '../../theme/app_spacing.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/error_dialog.dart';
import '../widgets/app_shell.dart';
import '../widgets/note_dialog.dart';
import '../widgets/state_widgets.dart';

/// Sets event counts to zero for one profile ([profileId]) or for everyone
/// on the event. Asks for a reason (kept in the audit trail). Returns true
/// when something was reset.
Future<bool> confirmResetCounts(
  BuildContext context,
  WidgetRef ref, {
  required String eventId,
  required String eventName,
  String? profileId,
  String? profileName,
}) async {
  final all = profileId == null;
  final note = await showNoteDialog(
    context,
    icon: Icons.restart_alt,
    destructive: true,
    title: all ? 'Set ALL counts to zero?' : 'Set ${profileName ?? 'this profile'} to zero?',
    message: '${all ? 'Every participant of "$eventName" will start again from 0 '
            'on the boards and reports, from today. ' : '${profileName ?? 'This profile'} will start again from 0 in '
            '"$eventName", from today. '}'
        'Steps walked before now no longer count, even if a phone uploads '
        'them later. Each walker\'s own count for today also restarts from '
        'zero on their phone the next time it syncs. Earlier days are kept, '
        'and you can undo this.',
    fieldLabel: 'Reason (required)',
    confirmLabel: 'Set to zero',
    minLength: 3,
    maxLength: 200,
  );
  if (note == null) return false;
  // Upload this phone's own steps first, so steps already walked are on the
  // server before the reset and cannot arrive afterwards looking new.
  try {
    await ref.read(stepTrackingProvider.future).timeout(const Duration(seconds: 5));
    await ref
        .read(stepTrackingProvider.notifier)
        .refresh()
        .timeout(const Duration(seconds: 8));
  } catch (_) {
    // No step tracking on this device, or offline: the reset still goes ahead.
  }
  try {
    final n = await ref
        .read(adminRepositoryProvider)
        .resetCounts(eventId, profileId: profileId, note: note);
    if (context.mounted) {
      showAppSnackBar(context, 'Reset $n profile${n == 1 ? '' : 's'} to zero.');
    }
    return true;
  } on CustomError catch (e) {
    if (context.mounted) errorDialog(context, e);
    return false;
  }
}

/// Brings back the counts a reset set aside.
Future<bool> confirmUndoReset(
  BuildContext context,
  WidgetRef ref, {
  required String eventId,
  String? profileId,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(profileId == null
          ? 'Undo the reset for everyone?'
          : 'Undo this reset?'),
      content: const Text(
          'The steps that were set aside count for the event again.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Undo reset')),
      ],
    ),
  );
  if (ok != true) return false;
  try {
    final n = await ref
        .read(adminRepositoryProvider)
        .undoReset(eventId, profileId: profileId);
    if (context.mounted) {
      showAppSnackBar(
          context,
          n == 0
              ? 'Nothing was reset.'
              : 'Counts restored for $n profile${n == 1 ? '' : 's'}.');
    }
    return true;
  } on CustomError catch (e) {
    if (context.mounted) errorDialog(context, e);
    return false;
  }
}

const _checkTitles = {
  'daily_totals_match_sources':
      'Daily totals match the phone/health-app readings',
  'weekly_totals_match_days':
      'Weekly leaderboard totals match the daily totals',
  'day_totals_match_days': 'Daily leaderboard totals match the daily totals',
  'days_over_40000_steps': 'Days over 40,000 steps (worth a look)',
  'same_steps_on_two_profiles_of_one_login':
      'Same steps on two profiles of one login (worth a look)',
  'event_total_vs_participant_list':
      'Event total equals the sum of the participant list',
  'event_total_not_above_raw_days':
      'Event total never exceeds the raw daily totals',
};

/// Recounts an event from the raw readings and shows any disagreement. The
/// repair button rebuilds daily and weekly totals from the raw readings.
class VerifyCountsPage extends ConsumerStatefulWidget {
  const VerifyCountsPage(
      {super.key, required this.eventId, required this.eventName});
  final String eventId;
  final String eventName;

  @override
  ConsumerState<VerifyCountsPage> createState() => _VerifyCountsPageState();
}

class _VerifyCountsPageState extends ConsumerState<VerifyCountsPage> {
  late Future<Map<String, dynamic>> _result = _run(false);

  Future<Map<String, dynamic>> _run(bool repair) => ref
      .read(adminRepositoryProvider)
      .validateCounts(widget.eventId, repair: repair);

  Future<void> _repair() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Repair totals?'),
        content: const Text('Daily and weekly totals are rebuilt from the raw '
            'readings. Raw readings are never changed. Count resets stay in force.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('Repair')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _result = _run(true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final canRepair = ref.watch(staffRoleProvider).value.canManage ||
        (ref.watch(isTransferReviewerProvider).value ?? false);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify counts'),
        actions: [
          IconButton(
              tooltip: 'Run again',
              icon: const Icon(Icons.refresh),
              onPressed: () => setState(() {
                    _result = _run(false);
                  })),
        ],
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _result,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const LoadingState();
          }
          if (snap.hasError) {
            final e = snap.error;
            return ErrorState(
                message: e is CustomError
                    ? e.message
                    : 'Could not check the counts.',
                onRetry: () => setState(() {
                      _result = _run(false);
                    }));
          }
          final r = snap.data!;
          final ok = r['ok'] == true;
          final checks = [
            for (final c in (r['checks'] as List))
              Map<String, dynamic>.from(c as Map)
          ];
          return PageContainer(
            child: ListView(padding: AppSpacing.pagePadding, children: [
              Card(
                color: ok ? scheme.primaryContainer : scheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Row(children: [
                    Icon(ok ? Icons.verified_outlined : Icons.error_outline,
                        color: ok
                            ? scheme.onPrimaryContainer
                            : scheme.onErrorContainer),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        r['repaired'] == true && ok
                            ? 'Repaired. Every count now matches the raw readings.'
                            : ok
                                ? 'Every count for "${widget.eventName}" matches the raw readings.'
                                : 'Some counts do not match. See below.',
                        style: text.titleSmall?.copyWith(
                            color: ok
                                ? scheme.onPrimaryContainer
                                : scheme.onErrorContainer),
                      ),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              for (final c in checks) _CheckTile(c: c),
              if (!ok && canRepair) ...[
                const SizedBox(height: AppSpacing.lg),
                FilledButton.icon(
                    onPressed: _repair,
                    icon: const Icon(Icons.build_outlined),
                    label: const Text('Repair totals')),
              ],
              const SizedBox(height: AppSpacing.lg),
              Text(
                'To see exactly how one person\'s total is made up, open them from the '
                'dashboard: each day shows every reading, what counted and why.',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ]),
          );
        },
      ),
    );
  }
}

class _CheckTile extends StatelessWidget {
  const _CheckTile({required this.c});
  final Map<String, dynamic> c;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ok = c['ok'] == true;
    final info = c['info'] == true;
    final name = c['check'] as String;
    final detail = c.containsKey('mismatches')
        ? '${c['mismatches']} found'
        : c.containsKey('counted')
            ? 'counted ${c['counted']} · raw ${c['raw_ceiling']}'
            : 'event ${c['event_days_total']} · list ${c['participant_list_total']}';
    final sample = (c['sample'] as List?) ?? const [];
    return Card(
      child: ExpansionTile(
        leading: Icon(
          ok
              ? Icons.check_circle_outline
              : (info ? Icons.info_outline : Icons.error_outline),
          color: ok ? scheme.primary : (info ? scheme.tertiary : scheme.error),
        ),
        title: Text(_checkTitles[name] ?? name),
        subtitle: Text(ok ? 'OK' : detail),
        children: [
          if (sample.isEmpty)
            const ListTile(dense: true, title: Text('Nothing to show.'))
          else
            for (final s in sample)
              ListTile(
                  dense: true,
                  title:
                      Text('$s', style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }
}
