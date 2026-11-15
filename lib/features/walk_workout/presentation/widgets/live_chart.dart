import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../application/walk_session_controller.dart';
import '../../domain/walk_models.dart';

enum ChartMetric { pace, heartRate, elevation }

/// Compact line chart of the walk so far, switchable between pace, heart
/// rate and elevation. Drawn in-app (no chart package).
class LiveChart extends StatefulWidget {
  const LiveChart({super.key, required this.series, required this.units, this.height = 120});
  final List<WorkoutMetric> series;
  final UnitSystem units;
  final double height;

  @override
  State<LiveChart> createState() => _LiveChartState();
}

class _LiveChartState extends State<LiveChart> {
  ChartMetric _metric = ChartMetric.pace;

  List<double> get _values => switch (_metric) {
        // shown as speed so "up" is faster
        ChartMetric.pace => [for (final m in widget.series) paceService.speedIn(widget.units, m.speed)],
        ChartMetric.heartRate => [
            for (final m in widget.series)
              if (m.bpm != null) m.bpm!.toDouble()
          ],
        ChartMetric.elevation => [
            for (final m in widget.series)
              if (m.altitude != null) m.altitude!
          ],
      };

  String get _unit => switch (_metric) {
        ChartMetric.pace => paceService.speedUnit(widget.units),
        ChartMetric.heartRate => 'bpm',
        ChartMetric.elevation => 'm',
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final v = _values;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration:
          BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(18)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SegmentedButton<ChartMetric>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(value: ChartMetric.pace, label: Text('Speed')),
            ButtonSegment(value: ChartMetric.heartRate, label: Text('Heart rate')),
            ButtonSegment(value: ChartMetric.elevation, label: Text('Elevation')),
          ],
          selected: {_metric},
          onSelectionChanged: (s) => setState(() => _metric = s.first),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: widget.height,
          child: v.length < 3
              ? Center(
                  child: Text(
                      _metric == ChartMetric.heartRate && widget.series.length >= 3
                          ? 'No heart-rate signal yet'
                          : 'The chart fills in after a few seconds of walking',
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      textAlign: TextAlign.center))
              : Semantics(
                  label: '${_metric.name} chart, from ${v.reduce(math.min).toStringAsFixed(1)} '
                      'to ${v.reduce(math.max).toStringAsFixed(1)} $_unit',
                  child: Stack(children: [
                    Positioned.fill(
                        child: CustomPaint(
                            painter: _LinePainter(v, scheme.primary, scheme.outlineVariant))),
                    Positioned(
                        right: 0,
                        top: 0,
                        child: Text('${v.reduce(math.max).toStringAsFixed(1)} $_unit',
                            style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant))),
                    Positioned(
                        right: 0,
                        bottom: 0,
                        child: Text('${v.reduce(math.min).toStringAsFixed(1)} $_unit',
                            style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant))),
                  ]),
                ),
        ),
      ]),
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.values, this.line, this.grid);
  final List<double> values;
  final Color line, grid;

  @override
  void paint(Canvas canvas, Size size) {
    final lo = values.reduce(math.min), hi = values.reduce(math.max);
    final span = math.max(hi - lo, 1e-6);
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final f in [0.0, 0.5, 1.0]) {
      canvas.drawLine(Offset(0, size.height * f), Offset(size.width, size.height * f), gridPaint);
    }
    Offset at(int i) => Offset(
        size.width * i / (values.length - 1), size.height - (values[i] - lo) / span * size.height);
    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < values.length; i++) {
      // smooth with a midpoint curve
      final a = at(i - 1), b = at(i);
      path.quadraticBezierTo(a.dx, a.dy, (a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
    }
    path.lineTo(at(values.length - 1).dx, at(values.length - 1).dy);
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [line.withValues(alpha: 0.35), line.withValues(alpha: 0)])
              .createShader(Offset.zero & size));
    canvas.drawPath(
        path,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.values.length != values.length || old.line != line;
}
