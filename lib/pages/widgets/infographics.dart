import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Duration for chart entrances: brief, ease-out, skipped under reduce motion.
Duration chartDuration(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 600);

/// Animates 0 -> 1 once when first shown; children scale their data by it.
class GrowIn extends StatelessWidget {
  const GrowIn({super.key, required this.builder});
  final Widget Function(BuildContext context, double t) builder;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: chartDuration(context),
        curve: Curves.easeOutCubic,
        builder: (c, t, _) => builder(c, t),
      );
}

/// A progress ring that animates to [value] (0..1) with a centre label.
class ProgressRing extends StatelessWidget {
  const ProgressRing({
    super.key,
    required this.value,
    required this.size,
    this.stroke = 10,
    this.color,
    this.center,
  });

  final double value;
  final double size;
  final double stroke;
  final Color? color;
  final Widget? center;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: value.clamp(0.0, 1.0)),
        duration: chartDuration(context),
        curve: Curves.easeOutCubic,
        builder: (context, v, child) => Stack(alignment: Alignment.center, children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: v,
              strokeWidth: stroke,
              strokeCap: StrokeCap.round,
              backgroundColor: scheme.surfaceContainerHighest,
              color: color ?? scheme.primary,
            ),
          ),
          if (child != null) child,
        ]),
        child: center,
      ),
    );
  }
}

class DonutSegment {
  const DonutSegment(this.value, this.color, this.label);
  final double value;
  final Color color;
  final String label;
}

/// A donut chart with a legend; segments sweep in once.
class DonutChart extends StatelessWidget {
  const DonutChart({super.key, required this.segments, this.size = 120, this.center});
  final List<DonutSegment> segments;
  final double size;
  final Widget? center;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final total = segments.fold<double>(0, (a, s) => a + s.value);
    return Semantics(
      label: segments.map((s) => '${s.label}: ${s.value.round()}').join(', '),
      excludeSemantics: true,
      child: Row(children: [
        SizedBox.square(
          dimension: size,
          child: GrowIn(
            builder: (c, t) => CustomPaint(
              painter: _DonutPainter(
                segments: segments,
                total: total,
                progress: t,
                track: Theme.of(c).colorScheme.surfaceContainerHighest,
              ),
              child: center == null ? null : Center(child: center),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final s in segments)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(color: s.color, shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${s.label}  ${s.value.round()}'
                        '${total > 0 ? ' (${(100 * s.value / total).round()}%)' : ''}',
                        style: text.bodyMedium,
                      ),
                    ),
                  ]),
                ),
            ],
          ),
        ),
      ]),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({required this.segments, required this.total, required this.progress, required this.track});
  final List<DonutSegment> segments;
  final double total;
  final double progress;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const w = 16.0;
    final rect = Offset.zero & size;
    final arc = rect.deflate(w / 2);
    canvas.drawArc(arc, 0, math.pi * 2, false,
        Paint()..color = track..style = PaintingStyle.stroke..strokeWidth = w);
    if (total <= 0) return;
    var start = -math.pi / 2;
    for (final s in segments) {
      final sweep = math.pi * 2 * (s.value / total) * progress;
      if (sweep > 0) {
        canvas.drawArc(arc, start, sweep, false,
            Paint()..color = s.color..style = PaintingStyle.stroke..strokeWidth = w);
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => old.progress != progress || old.segments != segments;
}
