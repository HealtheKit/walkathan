import 'package:flutter/material.dart';

import '../../theme/app_spacing.dart';

/// Shared frame for sign in / sign up / reset / change password screens.
///
/// Phone: a single scrolling column. Wide screens: branding panel on the
/// left, form on the right.
class AuthLayout extends StatelessWidget {
  const AuthLayout({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
    this.appBar,
    this.showLogo = true,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final PreferredSizeWidget? appBar;
  final bool showLogo;

  static const double _splitBreakpoint = 900;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final split = width >= _splitBreakpoint && appBar == null;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLogo && !split) ...[
          Image.asset(
            'assets/images/logo.png',
            width: 88,
            height: 88,
            semanticLabel: 'TEF Kuwait logo',
          ),
          const SizedBox(height: AppSpacing.xl),
        ],
        Text(title, style: text.headlineMedium),
        if (subtitle != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            subtitle!,
            style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
      ],
    );

    final form = Center(
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppSpacing.formMaxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [header, ...children],
          ),
        ),
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        appBar: appBar,
        body: SafeArea(
          child: split
              ? Row(
                  children: [
                    Expanded(child: _BrandPanel()),
                    Expanded(child: form),
                  ],
                )
              : form,
        ),
      ),
    );
  }
}

class _BrandPanel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      color: scheme.primaryContainer,
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/logo.png',
              width: 220,
              height: 220,
              semanticLabel: 'TEF Kuwait logo',
            ),
            const SizedBox(height: AppSpacing.xl),
            Text(
              'TEF Walkathon',
              style: text.displaySmall
                  ?.copyWith(color: scheme.onPrimaryContainer),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Walk together. Climb the leaderboard.',
              style: text.bodyLarge?.copyWith(
                color: scheme.onPrimaryContainer.withValues(alpha: .8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Not a member? Sign up" style footer row.
class AuthFooter extends StatelessWidget {
  const AuthFooter({super.key, required this.prompt, required this.action});

  final String prompt;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          prompt,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        action,
      ],
    );
  }
}
