import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_spacing.dart';
import '../../../theme/app_theme.dart';
import '../../widgets/app_shell.dart';
import './pedometer_provider.dart';

class WalkHomePage extends ConsumerStatefulWidget {
  final String userId;

  const WalkHomePage({required this.userId, super.key});

  @override
  ConsumerState<WalkHomePage> createState() => _WalkHomePageState();
}

class _WalkHomePageState extends ConsumerState<WalkHomePage> {
  late final PedometerManager _pedometerManager;

  @override
  void initState() {
    super.initState();
    final repo = ref.read(walkStepRepositoryProvider);
    _pedometerManager = PedometerManager(
      userId: widget.userId,
      walkStepRepository: repo,
    );
    _pedometerManager.stateNotifier.addListener(_onStateChanged);
    _pedometerManager.init();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _pedometerManager.stateNotifier.removeListener(_onStateChanged);
    _pedometerManager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pedometerState = _pedometerManager.state;

    return AppShell(
      current: AppTab.walk,
      title: 'Walk',
      body: PageContainer(
        child: ListView(
          padding: AppSpacing.pagePadding,
          children: [
            _StepsCard(state: pedometerState),
            const SizedBox(height: AppSpacing.lg),
            _StatusCard(status: pedometerState.status),
          ],
        ),
      ),
    );
  }
}

class _StepsCard extends StatelessWidget {
  const _StepsCard({required this.state});

  final PedometerState state;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final updated = state.lastUpdate != null
        ? 'Last updated ${DateFormat('HH:mm').format(state.lastUpdate!)}'
        : 'No updates yet';

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.xxl,
        ),
        child: Semantics(
          label: '${state.count} steps taken. $updated',
          excludeSemantics: true,
          child: Column(
            children: [
              Text(
                'STEPS TAKEN',
                style: text.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  NumberFormat.decimalPattern().format(state.count),
                  style: text.displayLarge?.copyWith(
                    color: scheme.primary,
                    fontFeatures: AppTheme.tabularFigures,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.schedule, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text(
                    updated,
                    style: text.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final brand = context.brand;

    final IconData icon;
    final Color color;
    final String title;
    String? detail;

    switch (status) {
      case 'walking':
        icon = Icons.directions_walk;
        color = brand.success;
        title = 'Walking';
      case 'stopped':
        icon = Icons.accessibility_new;
        color = scheme.primary;
        title = 'Stopped';
      case '?':
        icon = Icons.sensors;
        color = scheme.onSurfaceVariant;
        title = 'Waiting for sensor';
        detail = 'Start walking and your status will appear here.';
      default:
        icon = Icons.sensors_off;
        color = scheme.error;
        title = 'Status unavailable';
        detail = status;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .14),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 28, color: color),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Pedestrian status',
                    style: text.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  Text(title, style: text.titleLarge),
                  if (detail != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: text.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
