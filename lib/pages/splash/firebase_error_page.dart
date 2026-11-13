import 'package:flutter/material.dart';

import '../widgets/state_widgets.dart';

class FirebaseErrorPage extends StatelessWidget {
  const FirebaseErrorPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: ErrorState(
          title: 'Connection problem',
          message: "We couldn't reach the server. Please try again later.",
        ),
      ),
    );
  }
}
