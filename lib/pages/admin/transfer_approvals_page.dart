import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../features/transfer/transfer_models.dart';
import '../../models/custom_error.dart';
import '../../providers/profile_providers.dart';
import '../../theme/app_spacing.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/error_dialog.dart';
import '../widgets/app_shell.dart';
import '../widgets/note_dialog.dart';
import '../widgets/state_widgets.dart';

final _df = DateFormat.yMMMd().add_jm();
final _n = NumberFormat.decimalPattern();

final _pendingReviewsProvider =
    FutureProvider.autoDispose<List<TransferReview>>((ref) =>
        ref.watch(transferRepositoryProvider).review(status: 'pending'));

final _historyReviewsProvider =
    FutureProvider.autoDispose<List<TransferReview>>((ref) async {
  final all = await ref.watch(transferRepositoryProvider).review(status: null);
  return all.where((r) => !r.isPending).toList();
});

final _pendingDevicesProvider = FutureProvider.autoDispose<List<DeviceRequest>>(
    (ref) => ref
        .watch(transferRepositoryProvider)
        .deviceRequests(status: 'pending'));

final _historyDevicesProvider =
    FutureProvider.autoDispose<List<DeviceRequest>>((ref) async {
  final all =
      await ref.watch(transferRepositoryProvider).deviceRequests(status: null);
  return all.where((r) => !r.isPending).toList();
});

/// Super Admins and event organizers: approve or reject "new phone" profile
/// transfers for members on their events. The server re-checks every
/// decision, including that you may review this member.
class TransferApprovalsPage extends ConsumerWidget {
  const TransferApprovalsPage({super.key});

  void _refresh(WidgetRef ref) {
    ref.invalidate(_pendingReviewsProvider);
    ref.invalidate(_historyReviewsProvider);
    ref.invalidate(_pendingDevicesProvider);
    ref.invalidate(_historyDevicesProvider);
    ref.invalidate(pendingTransferCountProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reviewer = ref.watch(isTransferReviewerProvider);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Approvals'),
          leading: BackButton(onPressed: () {
            context.canPop() ? context.pop() : context.go('/home');
          }),
          actions: [
            IconButton(
                tooltip: 'Refresh',
                onPressed: () => _refresh(ref),
                icon: const Icon(Icons.refresh)),
          ],
          bottom: const TabBar(tabs: [
            Tab(text: 'Profile changes'),
            Tab(text: 'New phones'),
            Tab(text: 'History'),
          ]),
        ),
        body: reviewer.when(
          loading: () => const LoadingState(),
          error: (e, _) => ErrorState(
              message: 'Could not check your permissions.',
              onRetry: () => ref.invalidate(isTransferReviewerProvider)),
          data: (ok) => !ok
              ? const EmptyState(
                  icon: Icons.lock_outline,
                  title: 'Organizers only',
                  message:
                      'Only a Super Admin or an event organizer can approve profile changes and new phones.')
              : TabBarView(children: [
                  _List(
                      provider: _pendingReviewsProvider,
                      onChanged: () => _refresh(ref)),
                  _DeviceList(
                      provider: _pendingDevicesProvider,
                      onChanged: () => _refresh(ref)),
                  _HistoryTab(onChanged: () => _refresh(ref)),
                ]),
        ),
      ),
    );
  }
}

class _HistoryTab extends ConsumerWidget {
  const _HistoryTab({required this.onChanged});
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transfers = ref.watch(_historyReviewsProvider);
    final phones = ref.watch(_historyDevicesProvider);
    final text = Theme.of(context).textTheme;
    if (transfers.isLoading || phones.isLoading) return const LoadingState();
    final err = transfers.error ?? phones.error;
    if (err != null) {
      return ErrorState(
          message: err is CustomError ? err.message : 'Could not load history.',
          onRetry: onChanged);
    }
    final t = transfers.value ?? const <TransferReview>[];
    final d = phones.value ?? const <DeviceRequest>[];
    if (t.isEmpty && d.isEmpty) {
      return const EmptyState(
          icon: Icons.history,
          title: 'No history yet',
          message: 'Decided requests appear here.');
    }
    return PageContainer(
      child: ListView(padding: AppSpacing.pagePadding, children: [
        if (t.isNotEmpty) ...[
          Text('Profile changes', style: text.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          for (final r in t) ...[
            _ReviewCard(r: r, onChanged: onChanged),
            const SizedBox(height: AppSpacing.md),
          ],
        ],
        if (d.isNotEmpty) ...[
          Text('New phones', style: text.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          for (final r in d) ...[
            _DeviceCard(r: r, onChanged: onChanged),
            const SizedBox(height: AppSpacing.md),
          ],
        ],
      ]),
    );
  }
}

class _DeviceList extends ConsumerWidget {
  const _DeviceList({required this.provider, required this.onChanged});
  final FutureProvider<List<DeviceRequest>> provider;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(provider).when(
          loading: () => const LoadingState(),
          error: (e, _) => ErrorState(
              message:
                  e is CustomError ? e.message : 'Could not load requests.',
              onRetry: () => ref.invalidate(provider)),
          data: (rows) => rows.isEmpty
              ? const EmptyState(
                  icon: Icons.phone_android,
                  title: 'No new phones waiting',
                  message:
                      'When a member signs in on a new phone, it appears here.')
              : PageContainer(
                  child: ListView.separated(
                    padding: AppSpacing.pagePadding,
                    itemCount: rows.length,
                    separatorBuilder: (c, i) =>
                        const SizedBox(height: AppSpacing.md),
                    itemBuilder: (c, i) =>
                        _DeviceCard(r: rows[i], onChanged: onChanged),
                  ),
                ),
        );
  }
}

class _DeviceCard extends ConsumerStatefulWidget {
  const _DeviceCard({required this.r, required this.onChanged});
  final DeviceRequest r;
  final VoidCallback onChanged;

  @override
  ConsumerState<_DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends ConsumerState<_DeviceCard> {
  bool _busy = false;

  Future<void> _decide(bool approve) async {
    final r = widget.r;
    final noteText = await showNoteDialog(
      context,
      title: approve ? 'Approve this phone?' : 'Reject this phone?',
      message: approve
          ? '${r.email} will be able to sign in and count steps on this '
              '${r.label} (…${r.deviceTail}). Only approve it if you are '
              'sure it is the member\'s own phone.'
          : '${r.email} will not be able to use this phone. They can ask again.',
      fieldLabel: 'Note (optional)',
      confirmLabel: approve ? 'Approve' : 'Reject',
    );
    if (noteText == null) return;

    setState(() => _busy = true);
    try {
      final result = await ref.read(transferRepositoryProvider).decideDevice(r,
          approve: approve, note: noteText.isEmpty ? null : noteText);
      if (!mounted) return;
      showAppSnackBar(
          context,
          switch (result) {
            'approved' => 'Phone approved.',
            'rejected' => 'Phone rejected.',
            _ => 'Already handled.',
          });
      widget.onChanged();
    } on CustomError catch (e) {
      if (mounted) errorDialog(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.r;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final isSuper = ref.watch(staffRoleProvider).value == 'super';
    final blocked = r.ownRequest && !isSuper;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(r.email, style: text.titleMedium),
          Text(
              '${r.label} · …${r.deviceTail} · asked ${_df.format(r.requestedAt)}',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: AppSpacing.sm),
          Text(
            r.otherPhones == 0
                ? 'No other approved phone.'
                : '${r.otherPhones} other approved phone${r.otherPhones == 1 ? '' : 's'}'
                    '${r.lastOtherUse == null ? '' : ', last used ${_df.format(r.lastOtherUse!)}'}.',
            style: text.bodyMedium,
          ),
          if (r.isPending) ...[
            const SizedBox(height: AppSpacing.md),
            if (blocked)
              Text(
                  'This is your own phone. Another organizer or a Super Admin must approve it.',
                  style: text.bodySmall?.copyWith(color: scheme.error)),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              OutlinedButton(
                  onPressed: _busy ? null : () => _decide(false),
                  child: const Text('Reject')),
              const SizedBox(width: AppSpacing.sm),
              FilledButton(
                  onPressed: _busy || blocked ? null : () => _decide(true),
                  child: const Text('Approve')),
            ]),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text(
                '${r.status.label}${r.decidedAt == null ? '' : ' · ${_df.format(r.decidedAt!)}'}'
                '${r.decisionNote == null ? '' : '\n“${r.decisionNote}”'}',
                style: text.bodySmall?.copyWith(
                    color: r.status == TransferStatus.approved
                        ? scheme.primary
                        : scheme.onSurfaceVariant),
              ),
            ),
        ]),
      ),
    );
  }
}

class _List extends ConsumerWidget {
  const _List({required this.provider, required this.onChanged});
  final FutureProvider<List<TransferReview>> provider;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(provider).when(
          loading: () => const LoadingState(),
          error: (e, _) => ErrorState(
              message:
                  e is CustomError ? e.message : 'Could not load requests.',
              onRetry: () => ref.invalidate(provider)),
          data: (rows) => rows.isEmpty
              ? const EmptyState(
                  icon: Icons.verified_outlined,
                  title: 'Nothing here',
                  message: 'No profile change requests.')
              : PageContainer(
                  child: ListView.separated(
                    padding: AppSpacing.pagePadding,
                    itemCount: rows.length,
                    separatorBuilder: (c, i) =>
                        const SizedBox(height: AppSpacing.md),
                    itemBuilder: (c, i) =>
                        _ReviewCard(r: rows[i], onChanged: onChanged),
                  ),
                ),
        );
  }
}

class _ReviewCard extends ConsumerStatefulWidget {
  const _ReviewCard({required this.r, required this.onChanged});
  final TransferReview r;
  final VoidCallback onChanged;

  @override
  ConsumerState<_ReviewCard> createState() => _ReviewCardState();
}

class _ReviewCardState extends ConsumerState<_ReviewCard> {
  bool _busy = false;

  Future<void> _decide(bool approve) async {
    final r = widget.r;
    final noteText = await showNoteDialog(
      context,
      icon: approve ? Icons.warning_amber_rounded : Icons.block_outlined,
      destructive: approve,
      title: approve ? 'Approve and remove old profile?' : 'Reject request?',
      message: approve
          ? '"${r.sourceName}" (${_n.format(r.sourceSteps)} steps, '
              '${r.sourceDays} days) will be PERMANENTLY deleted and '
              'merged into "${r.targetName}" for ${r.email}.\n\n'
              'This cannot be undone.'
          : 'Nothing will change for ${r.email}. They can send a new request.',
      fieldLabel: 'Note (optional)',
      confirmLabel: approve ? 'Approve' : 'Reject',
    );
    if (noteText == null) return;

    setState(() => _busy = true);
    try {
      final result = await ref.read(transferRepositoryProvider).decide(r.id,
          approve: approve, note: noteText.isEmpty ? null : noteText);
      if (!mounted) return;
      showAppSnackBar(
          context,
          switch (result) {
            'approved' => 'Approved. Old profile merged and removed.',
            'rejected' => 'Rejected.',
            'profile_missing' => 'A profile no longer exists. Request closed.',
            _ => 'Already handled.',
          });
      widget.onChanged();
    } on CustomError catch (e) {
      if (mounted) errorDialog(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.r;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final isSuper = ref.watch(staffRoleProvider).value == 'super';
    final blocked = r.ownRequest && !isSuper;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r.email, style: text.titleMedium),
            Text('Requested ${_df.format(r.requestedAt)}',
                style:
                    text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: AppSpacing.md),
            _Row(
                icon: Icons.delete_outline,
                color: scheme.error,
                label: 'Old (removed)',
                name: r.sourceName,
                detail:
                    '${_n.format(r.sourceSteps)} steps · ${r.sourceDays} days'
                    '${r.sourceLastUpload == null ? '' : ' · last upload ${_df.format(r.sourceLastUpload!)}'}'),
            const SizedBox(height: AppSpacing.sm),
            _Row(
                icon: Icons.phone_android,
                color: scheme.primary,
                label: 'New (kept)',
                name: r.targetName,
                detail:
                    '${_n.format(r.targetSteps)} steps · ${r.targetDays} days'),
            const SizedBox(height: AppSpacing.md),
            Text('“${r.reason}”', style: text.bodyMedium),
            if (r.isPending) ...[
              const SizedBox(height: AppSpacing.md),
              if (blocked)
                Text(
                    'This is your own request. Another organizer or a Super Admin must approve it.',
                    style: text.bodySmall?.copyWith(color: scheme.error)),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                OutlinedButton(
                    onPressed: _busy ? null : () => _decide(false),
                    child: const Text('Reject')),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(
                    onPressed: _busy || blocked ? null : () => _decide(true),
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Approve')),
              ]),
            ] else ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                '${r.status.label}${r.decidedAt == null ? '' : ' · ${_df.format(r.decidedAt!)}'}'
                '${r.decisionNote == null ? '' : '\n“${r.decisionNote}”'}',
                style: text.bodySmall?.copyWith(
                    color: r.status == TransferStatus.approved
                        ? scheme.primary
                        : scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.color,
    required this.label,
    required this.name,
    required this.detail,
  });
  final IconData icon;
  final Color color;
  final String label;
  final String name;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: color, size: 20),
      const SizedBox(width: AppSpacing.sm),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$label: ${name.isEmpty ? '(no name)' : name}',
              style: text.bodyLarge),
          Text(detail, style: text.bodySmall),
        ]),
      ),
    ]);
  }
}
