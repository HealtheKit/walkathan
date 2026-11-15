import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/walk_models.dart';

/// The walked route drawn as a line, with start and current-position markers.
///
/// INTEGRATION POINT (maps): this is a self-contained drawing, not a map.
/// Replace the CustomPaint with google_maps_flutter / flutter_map and feed
/// it the same [points] as a polyline to get tiles, styles and zoom.
class RouteView extends StatelessWidget {
  const RouteView({super.key, required this.points, this.gpsOn = true, this.height = 190, this.live = true});
  final List<LocationPoint> points;
  final bool gpsOn;
  final double height;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    Widget child;
    if (!gpsOn) {
      child = _Message(
          icon: Icons.location_off_outlined,
          title: 'Walking without GPS',
          body: 'Distance and pace are estimated from your steps.');
    } else if (points.length < 2) {
      child = _Message(
          icon: Icons.gps_not_fixed,
          title: live ? 'Waiting for GPS signal' : 'No route recorded',
          body: live ? 'Your route appears here as you walk.' : null,
          busy: live);
    } else {
      child = Semantics(
        label: 'Route map with ${points.length} recorded points',
        child: CustomPaint(
          painter: _RoutePainter(points, line: scheme.primary, start: scheme.tertiary, here: scheme.onSurface),
          child: const SizedBox.expand(),
        ),
      );
    }
    return Container(
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(18)),
      child: Stack(children: [
        Positioned.fill(child: Padding(padding: const EdgeInsets.all(18), child: child)),
        if (gpsOn && points.length >= 2)
          Positioned(
            left: 12,
            top: 10,
            child: Text('ROUTE', style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.8)),
          ),
      ]),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, this.body, this.busy = false});
  final IconData icon;
  final String title;
  final String? body;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        busy
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
            : Icon(icon, color: scheme.onSurfaceVariant),
        const SizedBox(height: 8),
        Text(title, style: text.titleSmall, textAlign: TextAlign.center),
        if (body != null)
          Text(body!,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant), textAlign: TextAlign.center),
      ]),
    );
  }
}

class _RoutePainter extends CustomPainter {
  _RoutePainter(this.points, {required this.line, required this.start, required this.here});
  final List<LocationPoint> points;
  final Color line, start, here;

  @override
  void paint(Canvas canvas, Size size) {
    var minLat = points.first.lat, maxLat = minLat, minLon = points.first.lon, maxLon = minLon;
    for (final p in points) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLon = math.min(minLon, p.lon);
      maxLon = math.max(maxLon, p.lon);
    }
    // metres per degree, so the shape is not stretched
    final kLon = math.cos(((minLat + maxLat) / 2) * math.pi / 180);
    final w = math.max((maxLon - minLon) * kLon, 1e-6), h = math.max(maxLat - minLat, 1e-6);
    final scale = math.min(size.width / w, size.height / h);
    final ox = (size.width - w * scale) / 2, oy = (size.height - h * scale) / 2;
    Offset at(LocationPoint p) =>
        Offset(ox + (p.lon - minLon) * kLon * scale, size.height - oy - (p.lat - minLat) * scale);

    final path = Path()..moveTo(at(points.first).dx, at(points.first).dy);
    for (final p in points.skip(1)) {
      final o = at(p);
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round);
    canvas.drawCircle(at(points.first), 6, Paint()..color = start);
    final end = at(points.last);
    canvas.drawCircle(end, 9, Paint()..color = line.withValues(alpha: 0.3));
    canvas.drawCircle(end, 5, Paint()..color = here);
  }

  @override
  bool shouldRepaint(_RoutePainter old) => old.points.length != points.length || old.line != line;
}
