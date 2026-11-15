import 'package:flutter/material.dart';

/// One live figure: a small label, a large value and an optional unit and
/// caption. Read by screen readers as a single phrase ("Pace 9:05 min/km").
class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.caption,
    this.icon,
    this.accent,
    this.large = false,
  });

  final String label;
  final String value;
  final String? unit;
  final String? caption;
  final IconData? icon;
  final Color? accent;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final color = accent ?? scheme.onSurface;
    return Semantics(
      container: true,
      label: '$label ${value == '--' ? 'not available' : value} ${unit ?? ''}'
          '${caption == null ? '' : ', $caption'}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(label.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.8)),
              ),
            ]),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(value,
                      style: (large ? text.displaySmall : text.headlineSmall)?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()])),
                  if (unit != null && unit!.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Text(unit!, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ],
              ),
            ),
            if (caption != null)
              Text(caption!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
