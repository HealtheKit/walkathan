import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/transfer/transfer_models.dart';
import '../../models/custom_error.dart';
import '../../providers/profile_providers.dart';
import '../../theme/app_spacing.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/error_dialog.dart';
import '../widgets/note_dialog.dart';

/// Organizers of one event. There can be several; each can approve
/// "new phone" profile changes for members of this event. Only a Super
/// Admin (or an existing organizer of the event) can add or remove them,
/// which the server enforces.
class EventOrganizersCard extends ConsumerStatefulWidget {
  const EventOrganizersCard({super.key, required this.eventId});
  final String eventId;

  @override
  ConsumerState<EventOrganizersCard> createState() => _State();
}

class _State extends ConsumerState<EventOrganizersCard> {
  late Future<List<EventOrganizer>> _future = _load();

  Future<List<EventOrganizer>> _load() =>
      ref.read(transferRepositoryProvider).organizers(widget.eventId);

  void _reload() {
    setState(() {
      _future = _load();
    });
    ref.invalidate(isTransferReviewerProvider);
  }

  Future<void> _add() async {
    final value = await showNoteDialog(
      context,
      title: 'Add organizer',
      message: 'They can approve profile changes and new phones for members '
          'of this event. The person must already have a login with only one '
          'profile.',
      fieldLabel: 'Login email',
      confirmLabel: 'Add',
      keyboardType: TextInputType.emailAddress,
    );
    if (value == null || !value.contains('@')) return;
    try {
      final r = await ref
          .read(transferRepositoryProvider)
          .addOrganizer(widget.eventId, value);
      if (!mounted) return;
      if (r == 'not_found') {
        showAppSnackBar(context, 'No login with that email.', isError: true);
      } else if (r == 'multiple_profiles') {
        showAppSnackBar(
            context,
            'An organizer login can have only one profile. This login has '
            'several, so it can\'t be an organizer.',
            isError: true);
      } else {
        _reload();
      }
    } on CustomError catch (e) {
      if (mounted) errorDialog(context, e);
    }
  }

  Future<void> _remove(EventOrganizer o) async {
    try {
      await ref
          .read(transferRepositoryProvider)
          .removeOrganizer(widget.eventId, o.userId);
      _reload();
    } on CustomError catch (e) {
      if (mounted) errorDialog(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final canEdit = ref.watch(staffRoleProvider).value == 'super';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: FutureBuilder<List<EventOrganizer>>(
          future: _future,
          builder: (context, snap) {
            final list = snap.data ?? const <EventOrganizer>[];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                      child: Text('Organizers (${list.length})',
                          style: text.titleMedium)),
                  if (canEdit)
                    TextButton.icon(
                        onPressed: _add,
                        icon: const Icon(Icons.person_add_alt_1),
                        label: const Text('Add')),
                ]),
                if (snap.connectionState != ConnectionState.done)
                  const LinearProgressIndicator()
                else if (snap.hasError)
                  const Text('Could not load organizers.')
                else if (list.isEmpty)
                  const Text('No organizers yet. Only Super Admins can '
                      'approve profile changes for this event.')
                else
                  for (final o in list)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.how_to_reg_outlined),
                      title: Text(o.email),
                      trailing: canEdit
                          ? IconButton(
                              tooltip: 'Remove',
                              icon: const Icon(Icons.close),
                              onPressed: () => _remove(o))
                          : null,
                    ),
              ],
            );
          },
        ),
      ),
    );
  }
}
