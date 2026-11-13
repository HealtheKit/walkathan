import 'package:flutter/material.dart';

/// Primary action button with a built-in loading state.
///
/// Pass `onPressed: null` to disable; set [loading] to show a spinner and
/// block taps while keeping the button's size stable.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.icon,
    this.variant = AppButtonVariant.filled,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final IconData? icon;
  final AppButtonVariant variant;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    final VoidCallback? handler = enabled ? onPressed : null;

    final Widget content = AnimatedSwitcher(
      duration: const Duration(milliseconds: 150),
      child: loading
          ? SizedBox(
              key: const ValueKey('loading'),
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: variant == AppButtonVariant.filled
                    ? Theme.of(context).colorScheme.onPrimary
                    : Theme.of(context).colorScheme.primary,
              ),
            )
          : Row(
              key: const ValueKey('label'),
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20),
                  const SizedBox(width: 8),
                ],
                Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
              ],
            ),
    );

    // While loading, keep the button tappable-looking but inert so the
    // layout doesn't jump; Semantics announces the busy state.
    final Widget button = switch (variant) {
      AppButtonVariant.filled =>
        FilledButton(onPressed: handler, child: content),
      AppButtonVariant.outlined =>
        OutlinedButton(onPressed: handler, child: content),
    };

    return Semantics(
      button: true,
      enabled: enabled,
      label: loading ? '$label, loading' : label,
      excludeSemantics: true,
      child: button,
    );
  }
}

enum AppButtonVariant { filled, outlined }

/// Inline text link-style button used for secondary navigation
/// ("Sign up", "Forgot password?").
class AppTextButton extends StatelessWidget {
  const AppTextButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(onPressed: onPressed, child: Text(label));
  }
}
