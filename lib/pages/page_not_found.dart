import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../config/router/route_names.dart';
import 'widgets/buttons.dart';
import 'widgets/state_widgets.dart';

class PageNotFound extends StatelessWidget {
  final String errorMessage;
  const PageNotFound({
    super.key,
    required this.errorMessage,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: StateMessage(
                icon: Icons.explore_off_outlined,
                title: "We couldn't find that page",
                message: errorMessage,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: AppButton(
                  label: 'Go to Home',
                  icon: Icons.home_outlined,
                  onPressed: () =>
                      GoRouter.of(context).goNamed(RouteNames.home),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
