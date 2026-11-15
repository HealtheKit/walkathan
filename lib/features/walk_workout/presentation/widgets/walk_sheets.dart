import 'package:flutter/material.dart';

import '../../domain/walk_models.dart';

/// Audio, feedback and display options. Returns the changed settings.
Future<WorkoutSettings?> showWalkSettingsSheet(BuildContext context, WorkoutSettings initial,
    {bool duringWalk = false}) {
  return showModalBottomSheet<WorkoutSettings>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _SettingsSheet(initial: initial, duringWalk: duringWalk),
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.initial, required this.duringWalk});
  final WorkoutSettings initial;
  final bool duringWalk;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late WorkoutSettings _s = widget.initial;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom + 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Align(
                alignment: Alignment.centerLeft, child: Text('Walk settings', style: text.titleLarge)),
          ),
          ListTile(
            title: const Text('Units'),
            trailing: SegmentedButton<UnitSystem>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: UnitSystem.metric, label: Text('km')),
                ButtonSegment(value: UnitSystem.imperial, label: Text('mi')),
              ],
              selected: {_s.units},
              onSelectionChanged: (v) => setState(() => _s = _s.copyWith(units: v.first)),
            ),
          ),
          SwitchListTile(
            title: const Text('Voice coaching'),
            subtitle: const Text('Spoken updates as you walk'),
            value: _s.voiceCoaching,
            onChanged: (v) => setState(() => _s = _s.copyWith(voiceCoaching: v)),
          ),
          if (_s.voiceCoaching)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: SegmentedButton<VoiceInterval>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                      value: VoiceInterval.everyUnit,
                      label: Text(_s.units == UnitSystem.metric ? 'Every km' : 'Every mile')),
                  const ButtonSegment(value: VoiceInterval.everyFiveMinutes, label: Text('Every 5 min')),
                ],
                selected: {_s.voiceInterval == VoiceInterval.off ? VoiceInterval.everyUnit : _s.voiceInterval},
                onSelectionChanged: (v) => setState(() => _s = _s.copyWith(voiceInterval: v.first)),
              ),
            ),
          SwitchListTile(
            title: const Text('Auto pause'),
            subtitle: const Text('Pause when movement stops'),
            value: _s.autoPause,
            onChanged: (v) => setState(() => _s = _s.copyWith(autoPause: v)),
          ),
          if (!widget.duringWalk) ...[
            SwitchListTile(
              title: const Text('Heart-rate monitoring'),
              subtitle: const Text('If a sensor is available'),
              value: _s.heartRate,
              onChanged: (v) => setState(() => _s = _s.copyWith(heartRate: v)),
            ),
            SwitchListTile(
              title: const Text('Keep screen awake'),
              value: _s.keepScreenOn,
              onChanged: (v) => setState(() => _s = _s.copyWith(keepScreenOn: v)),
            ),
            SwitchListTile(
              title: const Text('Music controls'),
              subtitle: const Text('Show play / skip on the walk screen'),
              value: _s.musicControls,
              onChanged: (v) => setState(() => _s = _s.copyWith(musicControls: v)),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(onPressed: () => Navigator.pop(context, _s), child: const Text('Done')),
            ),
          ),
        ]),
      ),
    );
  }
}

enum FinishChoice { finish, resume, discard }

/// "Finish walk?" with Finish, Resume and Discard.
Future<FinishChoice?> showFinishSheet(BuildContext context) {
  return showModalBottomSheet<FinishChoice>(
    context: context,
    showDragHandle: true,
    builder: (c) {
      final scheme = Theme.of(c).colorScheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Finish walk?', style: Theme.of(c).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text('You can review it before saving.',
                style: Theme.of(c).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton(
                  onPressed: () => Navigator.pop(c, FinishChoice.finish), child: const Text('Finish')),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton.tonal(
                  onPressed: () => Navigator.pop(c, FinishChoice.resume), child: const Text('Resume')),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 48,
              child: TextButton(
                  onPressed: () => Navigator.pop(c, FinishChoice.discard),
                  child: Text('Discard', style: TextStyle(color: scheme.error))),
            ),
          ]),
        ),
      );
    },
  );
}

/// "Discard this walk?" confirmation.
Future<bool> confirmDiscard(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Discard this walk?'),
        content: const Text('It will not be saved. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Keep')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(d).colorScheme.error,
                  foregroundColor: Theme.of(d).colorScheme.onError),
              onPressed: () => Navigator.pop(d, true),
              child: const Text('Discard')),
        ],
      ),
    ) ==
    true;
