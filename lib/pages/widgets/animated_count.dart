import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// A number that rolls to its new value when it changes. Motion conveys the
/// state change only; it is skipped when the system asks for reduced motion.
class AnimatedCount extends StatelessWidget {
  const AnimatedCount({super.key, required this.value, this.style});

  final int value;
  final TextStyle? style;

  static final _fmt = NumberFormat.decimalPattern();

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: value.toDouble()),
      duration: reduce ? Duration.zero : const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => Text(_fmt.format(v.round()), style: style),
    );
  }
}
