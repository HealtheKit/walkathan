import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../theme/app_theme.dart';
import '../application/walk_session_controller.dart';
import '../domain/walk_models.dart';

/// Where the walk screens live. Any screen can go to the active walk through
/// this, so "Return to walk" never creates a second session.
class WalkNav {
  const WalkNav();
  static const setup = '/walk';
  static const active = '/walk/active';
  static const summary = '/walk/summary';

  void toSetup(BuildContext context) => context.push(setup);
  void toActive(BuildContext context) => context.push(active);
  void replaceWithActive(BuildContext context) => context.pushReplacement(active);
  void replaceWithSummary(BuildContext context) => context.pushReplacement(summary);
  void home(BuildContext context) => context.go('/home');
  void back(BuildContext context) => context.canPop() ? context.pop() : context.go('/home');

  /// The right screen for the walk's current state.
  void toWalk(BuildContext context, WalkSessionStatus status) {
    if (status == WalkSessionStatus.awaitingSave || status == WalkSessionStatus.saving) {
      context.push(summary);
    } else if (status.isLive) {
      context.push(active);
    } else {
      context.push(setup);
    }
  }
}

/// Overridden in widget tests (no router there).
final walkNavProvider = Provider<WalkNav>((ref) => const WalkNav());

/// The walk screens are always dark and high-contrast, whatever the app theme.
class WalkTheme extends StatelessWidget {
  const WalkTheme({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Theme(data: AppTheme.dark(), child: child);
}

/// Rebuilds once a second with the current time, so timers that are derived
/// from timestamps (paused time, the banner) keep moving even when the
/// session state itself does not change.
class SecondTicker extends ConsumerStatefulWidget {
  const SecondTicker({super.key, required this.builder});
  final Widget Function(BuildContext context, DateTime now) builder;

  @override
  ConsumerState<SecondTicker> createState() => _SecondTickerState();
}

class _SecondTickerState extends ConsumerState<SecondTicker> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (ref.read(walkAutoTickProvider)) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, ref.read(walkClockProvider)());
}

/// "A walk is already in progress." Returns after the user has chosen.
Future<void> showDuplicateWalkDialog(BuildContext context, WidgetRef ref) async {
  final nav = ref.read(walkNavProvider);
  final choice = await showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      icon: const Icon(Icons.directions_walk),
      title: const Text('A walk is already in progress.'),
      content: const Text('Only one walk can run at a time.'),
      actionsAlignment: MainAxisAlignment.center,
      actionsOverflowAlignment: OverflowBarAlignment.center,
      actions: [
        FilledButton(onPressed: () => Navigator.pop(d, 'return'), child: const Text('Return to walk')),
        OutlinedButton(
            onPressed: () => Navigator.pop(d, 'finish'), child: const Text('Finish current walk')),
        TextButton(
            onPressed: () => Navigator.pop(d, 'discard'),
            child: Text('Discard current walk', style: TextStyle(color: Theme.of(d).colorScheme.error))),
      ],
    ),
  );
  if (!context.mounted) return;
  final c = ref.read(walkSessionProvider.notifier);
  switch (choice) {
    case 'return':
      nav.toWalk(context, ref.read(walkStatusProvider));
    case 'finish':
      await c.finish();
      if (context.mounted) nav.toWalk(context, ref.read(walkStatusProvider));
    case 'discard':
      await c.discard();
  }
}
