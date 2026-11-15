import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../features/activity/step_providers.dart';
import '../../../features/transfer/transfer_models.dart';
import '../../../models/custom_error.dart';
import '../../../models/walker_profile.dart';
import '../../../providers/profile_providers.dart';
import '../../../theme/app_spacing.dart';
import '../../../utils/app_snackbar.dart';
import '../../../utils/error_dialog.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/state_widgets.dart';

final _df = DateFormat.yMMMd();

/// "I got a new phone": ask to move an OLD profile's data into the profile
/// used on this phone. The old profile is removed ONLY after a Super Admin
/// or an organizer approves; until then nothing changes.
class ProfileTransferPage extends ConsumerStatefulWidget {
  const ProfileTransferPage({super.key});

  @override
  ConsumerState<ProfileTransferPage> createState() =>
      _ProfileTransferPageState();
}

class _ProfileTransferPageState extends ConsumerState<ProfileTransferPage> {
  final _reason = TextEditingController();
  String? _sourceId;
  String? _targetId;
  bool _understood = false;
  bool _busy = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  bool get _valid =>
      _sourceId != null &&
      _targetId != null &&
      _sourceId != _targetId &&
      _reason.text.trim().length >= 5 &&
      _understood;

  Future<void> _submit(List<WalkerProfile> profiles) async {
    final source = profiles.firstWhere((p) => p.id == _sourceId);
    final target = profiles.firstWhere((p) => p.id == _targetId);
    final sure = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded,
            color: Theme.of(d).colorScheme.error, size: 36),
        title: const Text('Send for approval?'),
        content: Text(
          'If approved, "${_label(source)}" will be PERMANENTLY removed and '
          'its steps merged into "${_label(target)}". Friends and groups of '
          '"${_label(source)}" are not carried over.\n\n'
          'This cannot be undone. Nothing changes until an organizer '
          'approves.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Go back')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(d).colorScheme.error,
                  foregroundColor: Theme.of(d).colorScheme.onError),
              onPressed: () => Navigator.pop(d, true),
              child: const Text('Send request')),
        ],
      ),
    );
    if (sure != true) return;

    setState(() => _busy = true);
    try {
      final deviceId = await loadDeviceId(await SharedPreferences.getInstance());
      await ref.read(transferRepositoryProvider).request(
            sourceProfileId: source.id,
            targetProfileId: target.id,
            deviceId: deviceId,
            reason: _reason.text,
          );
      ref.invalidate(myTransfersProvider);
      if (!mounted) return;
      setState(() {
        _reason.clear();
        _understood = false;
        _sourceId = null;
      });
      showAppSnackBar(context, 'Sent. An organizer must approve it.');
    } on CustomError catch (e) {
      if (mounted) errorDialog(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(ProfileTransfer t) async {
    try {
      await ref.read(transferRepositoryProvider).cancel(t.id);
      ref.invalidate(myTransfersProvider);
    } on CustomError catch (e) {
      if (mounted) errorDialog(context, e);
    }
  }

  static String _label(WalkerProfile p) =>
      p.displayName.isEmpty ? p.relation.label : p.displayName;

  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(profilesProvider);
    final active = ref.watch(activeProfileProvider).value;
    final mine = ref.watch(myTransfersProvider);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Switch to a new phone'),
        leading: BackButton(onPressed: () {
          context.canPop() ? context.pop() : context.go('/profiles');
        }),
      ),
      body: profiles.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: e is CustomError ? e.message : 'Could not load profiles.',
          onRetry: () => ref.invalidate(profilesProvider),
        ),
        data: (list) {
          _targetId ??= active?.id ?? (list.isEmpty ? null : list.first.id);
          final pendingSources = {
            for (final t in mine.value ?? const <ProfileTransfer>[])
              if (t.isPending && t.sourceProfileId != null) t.sourceProfileId!
          };
          final sources = list.where((p) => p.id != _targetId).toList();

          return PageContainer(
            child: ListView(
              padding: AppSpacing.pagePadding,
              children: [
                Card(
                  color: scheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.warning_amber_rounded,
                              color: scheme.onErrorContainer),
                          const SizedBox(width: AppSpacing.sm),
                          Text('Please read first',
                              style: text.titleMedium?.copyWith(
                                  color: scheme.onErrorContainer)),
                        ]),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          '• The OLD phone\'s profile is permanently removed.\n'
                          '• Its steps, rest days and details move into the '
                          'profile on this phone.\n'
                          '• Friends and groups of the old profile are not '
                          'moved.\n'
                          '• This only happens after a Super Admin or an '
                          'organizer of your event approves it.\n'
                          '• It cannot be undone.',
                          style: text.bodyMedium
                              ?.copyWith(color: scheme.onErrorContainer),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                if (list.length < 2)
                  const EmptyState(
                      icon: Icons.people_outline,
                      title: 'You need two profiles',
                      message:
                          'Create the profile for the new phone first, then come back to move the old one into it.')
                else ...[
                  Text('1. Profile on THIS (new) phone', style: text.titleSmall),
                  const SizedBox(height: AppSpacing.sm),
                  DropdownButtonFormField<String>(
                    initialValue: _targetId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        helperText: 'Keeps its name and receives the data.'),
                    items: [
                      for (final p in list)
                        DropdownMenuItem(value: p.id, child: Text(_label(p))),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() {
                              _targetId = v;
                              if (_sourceId == v) _sourceId = null;
                            }),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text('2. OLD phone profile (will be removed)',
                      style: text.titleSmall),
                  const SizedBox(height: AppSpacing.sm),
                  DropdownButtonFormField<String>(
                    key: ValueKey('src-$_targetId-$_sourceId'),
                    initialValue: _sourceId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        hintText: 'Choose the profile to replace'),
                    items: [
                      for (final p in sources)
                        DropdownMenuItem(
                          value: p.id,
                          enabled: !pendingSources.contains(p.id),
                          child: Text(pendingSources.contains(p.id)
                              ? '${_label(p)} (request pending)'
                              : _label(p)),
                        ),
                    ],
                    onChanged:
                        _busy ? null : (v) => setState(() => _sourceId = v),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text('3. Why are you switching?', style: text.titleSmall),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: _reason,
                    enabled: !_busy,
                    maxLength: 300,
                    maxLines: 3,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                        hintText: 'e.g. My old phone broke and I bought a new one.'),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _understood,
                    onChanged:
                        _busy ? null : (v) => setState(() => _understood = v == true),
                    title: Text(
                        'I understand the old profile will be permanently removed once this is approved.',
                        style: text.bodyMedium),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  FilledButton.icon(
                    onPressed: _valid && !_busy ? () => _submit(list) : null,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send_outlined),
                    label: const Text('Request approval'),
                  ),
                ],
                const SizedBox(height: AppSpacing.xl),
                Text('Your requests', style: text.titleMedium),
                const SizedBox(height: AppSpacing.sm),
                mine.when(
                  loading: () => const Padding(
                      padding: EdgeInsets.all(AppSpacing.lg),
                      child: Center(child: CircularProgressIndicator())),
                  error: (e, _) => Text(
                      e is CustomError ? e.message : 'Could not load requests.'),
                  data: (rows) => rows.isEmpty
                      ? Text('No requests yet.',
                          style: text.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant))
                      : Column(children: [
                          for (final t in rows)
                            _RequestTile(
                                t: t, onCancel: () => _cancel(t)),
                        ]),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({required this.t, required this.onCancel});
  final ProfileTransfer t;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (t.status) {
      TransferStatus.approved => scheme.primary,
      TransferStatus.rejected => scheme.error,
      _ => scheme.onSurfaceVariant,
    };
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: ListTile(
        title: Text('${t.sourceName} → ${t.targetName}'),
        subtitle: Text(
          '${t.status.label} · ${_df.format(t.requestedAt)}'
          '${t.decisionNote == null ? '' : '\n“${t.decisionNote}”'}',
          style: TextStyle(color: color),
        ),
        isThreeLine: t.decisionNote != null,
        trailing: t.isPending
            ? TextButton(onPressed: onCancel, child: const Text('Cancel'))
            : null,
      ),
    );
  }
}
