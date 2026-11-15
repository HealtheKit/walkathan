import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/app_spacing.dart';
import 'admin_event_dashboard_page.dart' show eventOverviewProvider;
import 'count_tools.dart';

/// One switch per event: ON sets every profile of this event to zero (after
/// a confirmation and a reason), OFF brings the counts back. Nothing is
/// deleted either way. Only this event is affected.
class EventResetSwitch extends ConsumerWidget {
  const EventResetSwitch({super.key, required this.eventId, required this.eventName});
  final String eventId;
  final String eventName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(eventOverviewProvider(eventId));
    final scheme = Theme.of(context).colorScheme;

    final people = [
      for (final p in ((overview.value?['participants_detail'] as List?) ?? const []))
        Map<String, dynamic>.from(p as Map),
    ];
    final total = people.length;
    final reset = people.where((p) => p['reset_on'] != null).length;
    final allReset = total > 0 && reset == total;
    final dates = {for (final p in people) if (p['reset_on'] != null) '${p['reset_on']}'}.toList()
      ..sort();

    final String subtitle;
    if (overview.isLoading && overview.value == null) {
      subtitle = 'Checking…';
    } else if (overview.hasError && overview.value == null) {
      subtitle = 'Could not load the current state. Pull to refresh and try again.';
    } else if (total == 0) {
      subtitle = 'No profiles in this event yet.';
    } else if (allReset) {
      subtitle = 'On: all $total profiles count from zero since ${dates.last}. '
          'Turn off to bring the earlier steps back.';
    } else if (reset > 0) {
      subtitle = '$reset of $total profiles were set to zero individually. '
          'Turn on to set everyone to zero.';
    } else {
      subtitle = 'Off: counts are live. Turn on to set all $total profiles to zero '
          'for this event.';
    }

    Future<void> onChanged(bool on) async {
      final Future<bool> action = on
          ? confirmResetCounts(context, ref, eventId: eventId, eventName: eventName)
          : confirmUndoReset(context, ref, eventId: eventId);
      if (await action) ref.invalidate(eventOverviewProvider(eventId));
    }

    return Card(
      child: SwitchListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
        secondary: Icon(Icons.restart_alt, color: allReset ? scheme.error : scheme.primary),
        title: const Text('Set all profiles to zero'),
        subtitle: Text(subtitle),
        value: allReset,
        onChanged: overview.value == null || total == 0 ? null : onChanged,
      ),
    );
  }
}
