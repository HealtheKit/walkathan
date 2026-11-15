import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../features/admin/member_csv.dart';
import '../../models/custom_error.dart';
import '../../providers/profile_providers.dart';
import '../../repositories/admin_repository.dart';
import '../../theme/app_spacing.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/error_dialog.dart';
import '../widgets/app_shell.dart';
import 'admin_event_dashboard_page.dart';
import 'count_tools.dart';
import 'event_organizers_card.dart';
import 'event_reset_switch.dart';
import '../widgets/buttons.dart';
import '../widgets/state_widgets.dart';

final eventsProvider = FutureProvider.autoDispose<List<WalkEvent>>(
  (ref) => ref.watch(adminRepositoryProvider).listEvents(),
);

final _df = DateFormat.yMMMd();

/// Super Admin only: create events (date slots) and bulk-import their
/// members from a CSV email list. Authorization is enforced server-side.
class AdminEventsPage extends ConsumerWidget {
  const AdminEventsPage({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final created = await showDialog<bool>(
        context: context, builder: (_) => const _CreateEventDialog());
    if (created == true) ref.invalidate(eventsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Staff, or an organizer of at least one event (the server limits them
    // to their own events).
    final reviewer = ref.watch(isTransferReviewerProvider).value ?? false;
    final isAdmin =
        ref.watch(staffRoleProvider).whenData((r) => r.isStaff || reviewer);
    final canManage = ref.watch(staffRoleProvider).value.canManage;
    final events = ref.watch(eventsProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Events'),
        leading: BackButton(onPressed: () {
          context.canPop() ? context.pop() : context.go('/home');
        }),
        actions: [
          if (ref.watch(staffRoleProvider).value == 'super')
            IconButton(
                tooltip: 'Staff roles',
                icon: const Icon(Icons.admin_panel_settings_outlined),
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AdminStaffPage()))),
          IconButton(
              tooltip: 'Refresh',
              onPressed: () => ref.invalidate(eventsProvider),
              icon: const Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              onPressed: () => _create(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('New event'),
            )
          : null,
      body: isAdmin.when(
        loading: () => const LoadingState(),
        error: (e, st) => ErrorState(
            message: 'Could not check your permissions.',
            onRetry: () => ref.invalidate(staffRoleProvider)),
        data: (allowed) {
          if (!allowed) {
            return const EmptyState(
                icon: Icons.lock_outline,
                title: 'Staff only',
                message:
                    'Ask a Super Admin for an organizer, verifier or viewer role.');
          }
          return events.when(
            loading: () => const LoadingState(),
            error: (e, st) => ErrorState(
                message:
                    e is CustomError ? e.message : 'Could not load events.',
                onRetry: () => ref.invalidate(eventsProvider)),
            data: (list) {
              if (list.isEmpty) {
                return const EmptyState(
                    icon: Icons.event_outlined,
                    title: 'No events yet',
                    message:
                        'Create an event with its dates, then import its members from a CSV email list.');
              }
              return PageContainer(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  itemCount: list.length,
                  separatorBuilder: (c, i) =>
                      const SizedBox(height: AppSpacing.md),
                  itemBuilder: (context, i) {
                    final e = list[i];
                    return Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
                        leading: Icon(Icons.event, color: scheme.primary),
                        title: Text(e.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                            '${_df.format(e.startsOn)} – ${_df.format(e.endsOn)} · ${e.status}\n'
                            '${e.memberCount} member${e.memberCount == 1 ? '' : 's'}'),
                        isThreeLine: true,
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          await Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => EventDetailPage(event: e)));
                          ref.invalidate(eventsProvider);
                        },
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _CreateEventDialog extends ConsumerStatefulWidget {
  const _CreateEventDialog();

  @override
  ConsumerState<_CreateEventDialog> createState() => _CreateEventDialogState();
}

class _CreateEventDialogState extends ConsumerState<_CreateEventDialog> {
  final _name = TextEditingController();
  DateTimeRange? _range;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
      initialDateRange: _range,
    );
    if (r != null) setState(() => _range = r);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.length < 2) {
      setState(() => _error = 'Enter a name');
      return;
    }
    if (_range == null) {
      setState(() => _error = 'Choose the start and end dates');
      return;
    }
    if (_range!.duration.inDays > 365) {
      setState(() => _error = 'An event can last at most one year');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(adminRepositoryProvider).createEvent(
          name: name, startsOn: _range!.start, endsOn: _range!.end);
      if (mounted) Navigator.pop(context, true);
    } on CustomError catch (e) {
      setState(() {
        _saving = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New event'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            maxLength: 80,
            decoration: const InputDecoration(labelText: 'Event name'),
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: _pick,
            icon: const Icon(Icons.date_range),
            label: Text(_range == null
                ? 'Choose dates'
                : '${_df.format(_range!.start)} – ${_df.format(_range!.end)}'),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Create')),
      ],
    );
  }
}

class EventDetailPage extends ConsumerStatefulWidget {
  const EventDetailPage({super.key, required this.event});
  final WalkEvent event;

  @override
  ConsumerState<EventDetailPage> createState() => _EventDetailPageState();
}

class _EventDetailPageState extends ConsumerState<EventDetailPage> {
  late Future<List<RosterEntry>> _roster = _load();

  Future<List<RosterEntry>> _load() =>
      ref.read(adminRepositoryProvider).eventRoster(widget.event.id);

  void _reload() => setState(() {
        _roster = _load();
      });

  bool get _canManage => ref.read(staffRoleProvider).value.canManage;

  /// Staff who manage events, or organizers (server checks it is theirs).
  bool get _canCountTools =>
      _canManage || (ref.read(isTransferReviewerProvider).value ?? false);

  Future<void> _announce() async {
    final title = TextEditingController();
    final body = TextEditingController();
    var audience = 'all';
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => AlertDialog(
          title: const Text('Announcement'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'all', label: Text('All')),
                  ButtonSegment(value: 'male', label: Text('Men')),
                  ButtonSegment(value: 'female', label: Text('Women')),
                ],
                selected: {audience},
                onSelectionChanged: (s) => set(() => audience = s.first),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                  controller: title,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Title')),
              TextField(
                  controller: body,
                  maxLines: 4,
                  maxLength: 1000,
                  decoration: const InputDecoration(labelText: 'Message')),
              const Text(
                  'Shown on the Event tab. Push notifications are not enabled.'),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(d, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(d, true),
                child: const Text('Post')),
          ],
        ),
      ),
    );
    if (ok != true || title.text.trim().length < 2 || body.text.trim().isEmpty) {
      return;
    }
    try {
      await ref.read(adminRepositoryProvider).postAnnouncement(
          widget.event.id, audience, title.text.trim(), body.text.trim());
      if (mounted) showAppSnackBar(context, 'Announcement posted');
    } on CustomError catch (e) {
      if (mounted) errorDialog(context, e);
    }
  }

  Future<void> _import() async {
    final changed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => BulkImportPage(event: widget.event)));
    if (changed == true) _reload();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete event?'),
        content:
            Text('This deletes "${widget.event.name}" and its member list. '
                'Member accounts and their steps are kept.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(adminRepositoryProvider).deleteEvent(widget.event.id);
      if (mounted) Navigator.pop(context);
    } on CustomError catch (e) {
      if (mounted) errorDialog(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.event;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(e.name),
        actions: [
          if (_canManage)
            IconButton(
                tooltip: 'Delete event',
                onPressed: _delete,
                icon: const Icon(Icons.delete_outline)),
        ],
      ),
      floatingActionButton: _canManage
          ? FloatingActionButton.extended(
              onPressed: _import,
              icon: const Icon(Icons.upload_file),
              label: const Text('Import CSV'),
            )
          : null,
      body: FutureBuilder<List<RosterEntry>>(
        future: _roster,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const LoadingState();
          }
          if (snap.hasError) {
            final err = snap.error;
            return ErrorState(
                message: err is CustomError
                    ? err.message
                    : 'Could not load members.',
                onRetry: _reload);
          }
          final list = snap.data!;
          return PageContainer(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                Text(
                    '${_df.format(e.startsOn)} – ${_df.format(e.endsOn)} · ${e.status}',
                    style: text.bodyLarge
                        ?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: AppSpacing.md),
                Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      FilledButton.icon(
                        icon: const Icon(Icons.dashboard_outlined),
                        label: const Text('Dashboard'),
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) =>
                                    AdminEventDashboardPage(event: e))),
                      ),
                      if (_canCountTools) ...[
                        OutlinedButton.icon(
                          icon: const Icon(Icons.rule_folder_outlined),
                          label: const Text('Verify counts'),
                          onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => VerifyCountsPage(
                                      eventId: e.id, eventName: e.name))),
                        ),
                      ],
                      if (_canManage) ...[
                        OutlinedButton.icon(
                          icon: const Icon(Icons.tune),
                          label: const Text('Settings'),
                          onPressed: () async {
                            final saved = await Navigator.of(context)
                                .push<bool>(MaterialPageRoute(
                                    builder: (_) =>
                                        AdminEventSettingsPage(event: e)));
                            if (saved == true && context.mounted) {
                              Navigator.of(context).pop();
                            }
                          },
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.campaign_outlined),
                          label: const Text('Announce'),
                          onPressed: _announce,
                        ),
                      ],
                    ]),
                const SizedBox(height: AppSpacing.md),
                if (_canCountTools) ...[
                  EventResetSwitch(eventId: e.id, eventName: e.name),
                  const SizedBox(height: AppSpacing.md),
                ],
                EventOrganizersCard(eventId: e.id),
                const SizedBox(height: AppSpacing.sm),
                Text(
                    '${list.length} member${list.length == 1 ? '' : 's'} · '
                    '${list.where((m) => m.hasSignedIn).length} signed in',
                    style: text.titleMedium),
                const SizedBox(height: AppSpacing.md),
                if (list.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 48),
                    child: EmptyState(
                        icon: Icons.group_add_outlined,
                        title: 'No members yet',
                        message:
                            'Tap "Import CSV" to add the email list for this event.'),
                  ),
                for (final m in list)
                  Card(
                    margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                          m.hasSignedIn
                              ? Icons.check_circle_outline
                              : Icons.schedule,
                          color: m.hasSignedIn
                              ? scheme.primary
                              : scheme.onSurfaceVariant),
                      title: Text(m.email,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text([
                        m.hasSignedIn
                            ? '${m.profileCount} profile${m.profileCount == 1 ? '' : 's'}'
                            : 'has not signed in yet',
                        if (m.status != 'active') m.status,
                      ].join(' · ')),
                      trailing: !_canManage
                          ? null
                          : PopupMenuButton<String>(
                              tooltip: 'Participant options',
                              onSelected: (a) async {
                                final repo = ref.read(adminRepositoryProvider);
                                try {
                                  switch (a) {
                                    case 'block':
                                      await repo.setParticipantStatus(
                                          e.id, m.accountId, 'blocked');
                                    case 'reinstate':
                                      await repo.setParticipantStatus(
                                          e.id, m.accountId, 'active');
                                    case 'remove':
                                      await repo.removeFromEvent(
                                          e.id, m.accountId);
                                    case 'move':
                                      final events = (await repo.listEvents())
                                          .where((x) => x.id != e.id)
                                          .toList();
                                      if (!context.mounted || events.isEmpty) {
                                        return;
                                      }
                                      final to =
                                          await showModalBottomSheet<String>(
                                        context: context,
                                        builder: (c) => SafeArea(
                                            child: ListView(
                                                shrinkWrap: true,
                                                children: [
                                              for (final x in events)
                                                ListTile(
                                                    title: Text(x.name),
                                                    onTap: () =>
                                                        Navigator.pop(c, x.id)),
                                            ])),
                                      );
                                      if (to == null) return;
                                      await repo.moveParticipant(
                                          e.id, to, m.accountId);
                                  }
                                  _reload();
                                } on CustomError catch (err) {
                                  if (context.mounted) {
                                    errorDialog(context, err);
                                  }
                                }
                              },
                              itemBuilder: (_) => [
                                if (m.status == 'active')
                                  const PopupMenuItem(
                                      value: 'block', child: Text('Block'))
                                else
                                  const PopupMenuItem(
                                      value: 'reinstate',
                                      child: Text('Reinstate')),
                                const PopupMenuItem(
                                    value: 'move',
                                    child: Text('Move to another event')),
                                const PopupMenuItem(
                                    value: 'remove', child: Text('Remove')),
                              ],
                            ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Paste a CSV email list, review what will happen, import, then copy the
/// one-time sign-in details for the new accounts.
class BulkImportPage extends ConsumerStatefulWidget {
  const BulkImportPage({super.key, required this.event});
  final WalkEvent event;

  @override
  ConsumerState<BulkImportPage> createState() => _BulkImportPageState();
}

class _BulkImportPageState extends ConsumerState<BulkImportPage> {
  final _csv = TextEditingController();
  MemberCsvResult? _parsed;
  List<ImportOutcome>? _results;
  bool _running = false;
  int _done = 0;

  @override
  void dispose() {
    _csv.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final rows = _parsed!.rows;
    setState(() {
      _running = true;
      _done = 0;
    });
    final repo = ref.read(adminRepositoryProvider);
    final results = await importInChunks(
      rows: rows,
      send: (chunk) => repo.bulkImportChunk(widget.event.id, chunk),
      onProgress: (done, total) {
        if (mounted) setState(() => _done = done);
      },
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _results = results;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: !_running,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Import members'),
          leading: BackButton(
              onPressed: _running
                  ? null
                  : () => Navigator.pop(context, _results != null)),
        ),
        body: PageContainer(
          child: ListView(
            padding: AppSpacing.pagePadding,
            children: _results != null
                ? _resultView(text, scheme)
                : _inputView(text, scheme),
          ),
        ),
      ),
    );
  }

  List<Widget> _inputView(TextTheme text, ColorScheme scheme) {
    final p = _parsed;
    return [
      Text('Add members to "${widget.event.name}"', style: text.titleMedium),
      const SizedBox(height: AppSpacing.sm),
      Text(
        'Paste the CSV: one member per line, as  email  or  email,name . '
        'A header line is fine. New emails get an account with a temporary '
        'password; emails that already have an account are just added to '
        'this event.',
        style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
      const SizedBox(height: AppSpacing.lg),
      TextField(
        controller: _csv,
        enabled: !_running,
        maxLines: 10,
        minLines: 6,
        autocorrect: false,
        keyboardType: TextInputType.multiline,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: const InputDecoration(
          hintText: 'email,name\npriya@example.com,Priya\nsam@example.com',
          alignLabelWithHint: true,
        ),
        onChanged: (_) {
          if (_parsed != null) setState(() => _parsed = null);
        },
      ),
      const SizedBox(height: AppSpacing.md),
      Row(children: [
        OutlinedButton.icon(
          onPressed: _running
              ? null
              : () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null) {
                    _csv.text = data!.text!;
                    setState(() => _parsed = null);
                  }
                },
          icon: const Icon(Icons.content_paste),
          label: const Text('Paste'),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: AppButton(
            label: 'Check list',
            variant: AppButtonVariant.outlined,
            onPressed: _running
                ? null
                : () => setState(() => _parsed = parseMemberCsv(_csv.text)),
          ),
        ),
      ]),
      if (p != null) ...[
        const SizedBox(height: AppSpacing.lg),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    '${p.rows.length} valid email${p.rows.length == 1 ? '' : 's'}',
                    style: text.titleMedium),
                if (p.duplicates > 0)
                  Text(
                      '${p.duplicates} duplicate line${p.duplicates == 1 ? '' : 's'} ignored',
                      style: text.bodyMedium),
                if (p.issues.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                      '${p.issues.length} line${p.issues.length == 1 ? '' : 's'} will be skipped:',
                      style: text.bodyMedium?.copyWith(color: scheme.error)),
                  for (final i in p.issues.take(8))
                    Text('Line ${i.line}: ${i.text}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall),
                  if (p.issues.length > 8)
                    Text('…and ${p.issues.length - 8} more',
                        style: text.bodySmall),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        if (_running) ...[
          LinearProgressIndicator(
              value: p.rows.isEmpty ? null : _done / p.rows.length),
          const SizedBox(height: AppSpacing.sm),
          Text('Importing $_done of ${p.rows.length}… keep this screen open.',
              textAlign: TextAlign.center, style: text.bodyMedium),
        ] else
          AppButton(
            label:
                'Import ${p.rows.length} member${p.rows.length == 1 ? '' : 's'}',
            icon: Icons.upload,
            onPressed: p.rows.isEmpty ? null : _run,
          ),
      ],
    ];
  }

  List<Widget> _resultView(TextTheme text, ColorScheme scheme) {
    final r = _results!;
    final created = r.where((o) => o.status == 'created').toList();
    final existing = r.where((o) => o.status == 'existing').length;
    final failed =
        r.where((o) => o.status == 'error' || o.status == 'invalid').toList();

    return [
      Text('Import finished', style: text.titleLarge),
      const SizedBox(height: AppSpacing.md),
      Text(
          '${created.length} new account${created.length == 1 ? '' : 's'} created',
          style: text.bodyLarge),
      Text(
          '$existing existing account${existing == 1 ? '' : 's'} added to the event',
          style: text.bodyLarge),
      if (failed.isNotEmpty)
        Text(
            '${failed.length} failed (see below). You can import the same list again safely.',
            style: text.bodyLarge?.copyWith(color: scheme.error)),
      if (created.isNotEmpty) ...[
        const SizedBox(height: AppSpacing.lg),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Temporary passwords', style: text.titleMedium),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'These are shown only now and are not stored anywhere. Copy '
                  'them before leaving this screen and share each one '
                  'privately. Members must choose a new password at first sign-in.',
                  style:
                      text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  label: 'Copy all as CSV',
                  icon: Icons.copy,
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(
                        text: credentialsCsv([
                      for (final c in created)
                        (email: c.email, password: c.tempPassword ?? ''),
                    ])));
                    if (mounted) {
                      showAppSnackBar(
                          context, 'Copied ${created.length} sign-in details');
                    }
                  },
                ),
                const SizedBox(height: AppSpacing.md),
                for (final c in created)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: SelectableText(
                        '${c.email}   ${c.tempPassword ?? ''}',
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 13)),
                  ),
              ],
            ),
          ),
        ),
      ],
      if (failed.isNotEmpty) ...[
        const SizedBox(height: AppSpacing.lg),
        Text('Failed', style: text.titleMedium),
        for (final f in failed)
          Text('${f.email} (${f.status})', style: text.bodyMedium),
      ],
      const SizedBox(height: AppSpacing.xl),
      AppButton(
        label: 'Done',
        variant: AppButtonVariant.outlined,
        onPressed: () => Navigator.pop(context, true),
      ),
    ];
  }
}
