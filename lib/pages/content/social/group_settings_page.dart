import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../features/social/social_models.dart';
import '../../../features/social/social_providers.dart';
import '../../../models/custom_error.dart';
import '../../../providers/profile_providers.dart';
import '../../../theme/app_spacing.dart';
import '../../../utils/app_snackbar.dart';
import '../../../utils/error_dialog.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/buttons.dart';
import '../../widgets/state_widgets.dart';

final _day = DateFormat.yMMMd();

/// Admin-only settings for a group. The server re-checks every permission;
/// this screen only decides what to show. Pops `true` when the group is gone
/// (deleted or left).
class GroupSettingsPage extends ConsumerStatefulWidget {
  const GroupSettingsPage({super.key, required this.group});
  final GroupInfo group;

  @override
  ConsumerState<GroupSettingsPage> createState() => _GroupSettingsPageState();
}

class _GroupSettingsPageState extends ConsumerState<GroupSettingsPage> {
  late final _name = TextEditingController(text: widget.group.name);
  late bool _chat = widget.group.chatEnabled;
  late bool _taunts = widget.group.tauntsEnabled;
  late bool _mystery = widget.group.mysteryMode;
  late DateTime? _cStart = widget.group.challengeStart;
  late DateTime? _cEnd = widget.group.challengeEnd;
  String? _inviteCode;
  bool _busy = false;

  String get _gid => widget.group.id;
  bool get _isOwner => widget.group.role == GroupRole.owner;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Runs an admin action with the active profile, showing errors.
  Future<bool> _do(Future<void> Function(SocialRepository repo, String me) action,
      {String? done}) async {
    final me = ref.read(activeProfileProvider).value?.id;
    if (me == null || _busy) return false;
    setState(() => _busy = true);
    try {
      await action(ref.read(socialRepositoryProvider), me);
      if (mounted && done != null) showAppSnackBar(context, done);
      return true;
    } on CustomError catch (e) {
      if (mounted) errorDialog(context, e);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
          ],
        ),
      ) ==
      true;

  Future<void> _toggle(void Function(bool) apply, bool value,
      {bool? chat, bool? taunts, bool? mystery}) async {
    setState(() => apply(value));
    final ok = await _do((r, me) =>
        r.updateGroup(me, _gid, chat: chat, taunts: taunts, mystery: mystery));
    if (!ok && mounted) setState(() => apply(!value)); // roll back on failure
  }

  Future<void> _pickChallenge() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
      initialDateRange:
          _cStart != null && _cEnd != null ? DateTimeRange(start: _cStart!, end: _cEnd!) : null,
      helpText: 'Challenge dates (1 day to 1 year)',
    );
    if (range == null) return;
    if (range.duration.inDays > 365) {
      if (mounted) {
        showAppSnackBar(context, 'A challenge can last at most one year.', isError: true);
      }
      return;
    }
    if (await _do((r, me) => r.setChallenge(me, _gid, range.start, range.end),
        done: 'Challenge saved')) {
      setState(() {
        _cStart = range.start;
        _cEnd = range.end;
      });
    }
  }

  Future<void> _export() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
      initialDateRange: DateTimeRange(
          start: DateTime(now.year, now.month, now.day - 6), end: now),
      helpText: 'Report dates',
    );
    if (range == null) return;
    await _do((r, me) async {
      final report = await r.exportReport(me, _gid, range.start, range.end);
      await Clipboard.setData(ClipboardData(text: groupReportCsv(report)));
    }, done: 'Report copied as CSV. Paste it into a spreadsheet or email.');
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final members = ref.watch(groupMembersProvider(_gid));

    Widget heading(String t) => Padding(
          padding: const EdgeInsets.only(top: AppSpacing.xl, bottom: AppSpacing.sm),
          child: Text(t, style: text.titleMedium),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Group settings')),
      body: PageContainer(
        child: ListView(
          padding: AppSpacing.pagePadding,
          children: [
            // ---- name ----
            TextField(
              controller: _name,
              maxLength: 60,
              decoration: InputDecoration(
                labelText: 'Group name',
                suffixIcon: IconButton(
                  tooltip: 'Save name',
                  icon: const Icon(Icons.check),
                  onPressed: () => _do(
                      (r, me) => r.updateGroup(me, _gid, name: _name.text.trim()),
                      done: 'Name saved'),
                ),
              ),
            ),

            // ---- switches ----
            heading('Options'),
            Card(
              child: Column(children: [
                SwitchListTile(
                  value: _mystery,
                  onChanged: _busy ? null : (v) => _toggle((x) => _mystery = x, v, mystery: v),
                  title: const Text('Mystery Mode'),
                  subtitle: const Text(
                      'Hides today\'s step counts and shows ranks only. Counts '
                      'are revealed the next day.'),
                ),
                const Divider(),
                SwitchListTile(
                  value: _chat,
                  onChanged: _busy ? null : (v) => _toggle((x) => _chat = x, v, chat: v),
                  title: const Text('Group chat'),
                  subtitle: const Text('Saved now; applies when chat is released.'),
                ),
                const Divider(),
                SwitchListTile(
                  value: _taunts,
                  onChanged: _busy ? null : (v) => _toggle((x) => _taunts = x, v, taunts: v),
                  title: const Text('Taunts'),
                  subtitle: const Text('Saved now; applies when chat is released.'),
                ),
              ]),
            ),

            // ---- challenge ----
            heading('Fixed-date challenge'),
            Text(
              _cStart == null
                  ? 'The group runs as an ongoing challenge. Add dates for a '
                      'separate fixed-date board.'
                  : '${_day.format(_cStart!)} – ${_day.format(_cEnd!)}. Its board '
                      'stays available after it ends until you change or clear it.',
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(children: [
              Expanded(
                child: AppButton(
                  label: _cStart == null ? 'Set dates' : 'Change dates',
                  icon: Icons.date_range,
                  variant: AppButtonVariant.outlined,
                  onPressed: _busy ? null : _pickChallenge,
                ),
              ),
              if (_cStart != null) ...[
                const SizedBox(width: AppSpacing.md),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          if (await _do((r, me) => r.setChallenge(me, _gid, null, null),
                              done: 'Challenge cleared')) {
                            setState(() => _cStart = _cEnd = null);
                          }
                        },
                  child: const Text('Clear'),
                ),
              ],
            ]),

            // ---- invites ----
            heading('Invite people'),
            if (_inviteCode != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(_inviteCode!,
                          style: text.headlineSmall?.copyWith(letterSpacing: 2)),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'Valid for 14 days. Shown only now, so copy it before '
                        'leaving this screen.',
                        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      AppButton(
                        label: 'Copy invitation',
                        icon: Icons.copy,
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(
                              text: 'Join my group "${_name.text.trim()}" in the '
                                  'Tresundios TEF Walkathon app. Open Social > Groups > '
                                  'Join with code and enter: $_inviteCode'));
                          if (context.mounted) {
                            showAppSnackBar(context,
                                'Invitation copied. Paste it into a text or email.');
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
            Row(children: [
              Expanded(
                child: AppButton(
                  label: 'New invite code',
                  icon: Icons.vpn_key_outlined,
                  variant: AppButtonVariant.outlined,
                  onPressed: _busy
                      ? null
                      : () => _do((r, me) async {
                            final code = await r.createInvite(me, _gid);
                            if (mounted) setState(() => _inviteCode = code);
                          }),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        if (await _confirm('Revoke all codes?',
                            'Every invite code for this group stops working.', 'Revoke')) {
                          if (await _do((r, me) => r.revokeInvites(me, _gid),
                              done: 'All invite codes revoked')) {
                            setState(() => _inviteCode = null);
                          }
                        }
                      },
                child: const Text('Revoke all'),
              ),
            ]),

            // ---- report ----
            heading('Report'),
            Text(
              'Totals per member for any date range, as CSV. Use one group '
              'per team to compare teams in a spreadsheet.',
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.md),
            AppButton(
              label: 'Export report',
              icon: Icons.table_view_outlined,
              variant: AppButtonVariant.outlined,
              onPressed: _busy ? null : _export,
            ),

            // ---- members ----
            heading('Members'),
            members.when(
              loading: () => const Padding(
                  padding: EdgeInsets.all(AppSpacing.lg), child: LoadingState()),
              error: (e, _) => ErrorState(
                  message: 'Could not load members.',
                  onRetry: () => ref.invalidate(groupMembersProvider(_gid))),
              data: (list) => Card(
                child: Column(children: [
                  for (final m in list)
                    ListTile(
                      title: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(m.mine ? '${m.role.label} · you' : m.role.label),
                      trailing: _memberMenu(m),
                    ),
                ]),
              ),
            ),

            // ---- danger ----
            const SizedBox(height: AppSpacing.xxl),
            if (_isOwner)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                    foregroundColor: scheme.error, side: BorderSide(color: scheme.error)),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete group'),
                onPressed: _busy
                    ? null
                    : () async {
                        final nav = Navigator.of(context);
                        if (await _confirm(
                            'Delete group?',
                            'This removes the group, its boards and invite codes for '
                                'everyone. Members keep their own steps.',
                            'Delete')) {
                          if (await _do((r, me) => r.deleteGroup(me, _gid))) nav.pop(true);
                        }
                      },
              )
            else
              OutlinedButton.icon(
                icon: const Icon(Icons.logout),
                label: const Text('Leave group'),
                onPressed: _busy
                    ? null
                    : () async {
                        final nav = Navigator.of(context);
                        if (await _confirm('Leave group?',
                            'You can rejoin only with a new invite code.', 'Leave')) {
                          if (await _do((r, me) => r.leaveGroup(me, _gid))) nav.pop(true);
                        }
                      },
              ),
          ],
        ),
      ),
    );
  }

  /// What the signed-in admin may do to [m]. Mirrors the server rules.
  Widget? _memberMenu(GroupMember m) {
    final me = ref.read(activeProfileProvider).value?.id;
    if (m.profileId == me || m.role == GroupRole.owner) return null;
    final canRemove = _isOwner || m.role == GroupRole.member;
    if (!canRemove && !_isOwner) return null;

    return PopupMenuButton<String>(
      tooltip: 'Member options',
      onSelected: (a) async {
        bool ok = false;
        switch (a) {
          case 'remove':
            if (await _confirm('Remove member?',
                '${m.name} is removed from the group and its boards.', 'Remove')) {
              ok = await _do((r, me) => r.removeMember(me, _gid, m.profileId),
                  done: 'Member removed');
            }
          case 'admin':
            ok = await _do((r, me) => r.setRole(me, _gid, m.profileId, GroupRole.admin),
                done: '${m.name} is now an admin');
          case 'member':
            ok = await _do((r, me) => r.setRole(me, _gid, m.profileId, GroupRole.member),
                done: '${m.name} is now a member');
          case 'owner':
            if (await _confirm(
                'Hand over the group?',
                '${m.name} becomes the owner and you become an admin.',
                'Hand over')) {
              ok = await _do((r, me) => r.setRole(me, _gid, m.profileId, GroupRole.owner));
              if (ok && mounted) Navigator.of(context).pop(false);
            }
        }
        if (ok) ref.invalidate(groupMembersProvider(_gid));
      },
      itemBuilder: (_) => [
        if (_isOwner && m.role == GroupRole.member)
          const PopupMenuItem(value: 'admin', child: Text('Make admin')),
        if (_isOwner && m.role == GroupRole.admin)
          const PopupMenuItem(value: 'member', child: Text('Remove admin role')),
        if (_isOwner) const PopupMenuItem(value: 'owner', child: Text('Make owner')),
        if (canRemove) const PopupMenuItem(value: 'remove', child: Text('Remove from group')),
      ],
    );
  }
}
