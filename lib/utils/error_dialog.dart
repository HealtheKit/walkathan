import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

import '../models/custom_error.dart';

void errorDialog(BuildContext context, CustomError e) {
  if (defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS) {
    showCupertinoDialog(
      context: context,
      builder: (context) {
        return CupertinoAlertDialog(
          title: const Text('Something went wrong'),
          content: Text(e.message),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              child: const Text('OK'),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  } else {
    showDialog(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          icon: Icon(Icons.error_outline, color: scheme.error, size: 32),
          title: const Text('Something went wrong'),
          content: Text(e.message),
          actionsAlignment: MainAxisAlignment.end,
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(88, 44)),
              child: const Text('OK'),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  }
}
