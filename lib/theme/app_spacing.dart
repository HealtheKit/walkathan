import 'package:flutter/widgets.dart';

/// 4/8-pt spacing scale, radii and layout breakpoints.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  static const double radiusField = 12;
  static const double radiusCard = 16;
  static const double radiusSheet = 28;

  /// Below this width: single column + bottom navigation.
  static const double compactMax = 600;

  /// From this width: navigation rail + two-column content.
  static const double expandedMin = 840;

  static const double contentMaxWidth = 720;
  static const double formMaxWidth = 440;

  static const EdgeInsets pagePadding = EdgeInsets.fromLTRB(16, 16, 16, 24);
}

extension ResponsiveContext on BuildContext {
  double get _width => MediaQuery.sizeOf(this).width;
  bool get isCompact => _width < AppSpacing.compactMax;
  bool get isExpanded => _width >= AppSpacing.expandedMin;
}
