import 'package:flutter/material.dart';

import '../../theme/app_spacing.dart';

/// A confirmation dialog with one text box. The dialog OWNS its text
/// controller, so it is disposed only when the dialog is really gone.
/// (Disposing a controller right after `showDialog` returns, while the
/// dialog is still animating out, throws during a rebuild and shows the red
/// error screen.)
///
/// Returns the entered text (possibly empty) when confirmed, or null when
/// cancelled.
Future<String?> showNoteDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  required String fieldLabel,
  String? message,
  IconData? icon,
  bool destructive = false,
  int minLength = 0,
  int maxLength = 300,
  int maxLines = 1,
  TextInputType? keyboardType,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _NoteDialog(
      title: title,
      confirmLabel: confirmLabel,
      fieldLabel: fieldLabel,
      message: message,
      icon: icon,
      destructive: destructive,
      minLength: minLength,
      maxLength: maxLength,
      maxLines: maxLines,
      keyboardType: keyboardType,
    ),
  );
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({
    required this.title,
    required this.confirmLabel,
    required this.fieldLabel,
    required this.minLength,
    required this.maxLength,
    required this.maxLines,
    required this.destructive,
    this.message,
    this.icon,
    this.keyboardType,
  });

  final String title;
  final String confirmLabel;
  final String fieldLabel;
  final String? message;
  final IconData? icon;
  final bool destructive;
  final int minLength;
  final int maxLength;
  final int maxLines;
  final TextInputType? keyboardType;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _valid => _controller.text.trim().length >= widget.minLength;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: widget.icon == null
          ? null
          : Icon(widget.icon,
              color: widget.destructive ? scheme.error : scheme.primary, size: 36),
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (widget.message != null) ...[
            Text(widget.message!),
            const SizedBox(height: AppSpacing.md),
          ],
          TextField(
            controller: _controller,
            autofocus: true,
            maxLength: widget.maxLength,
            maxLines: widget.maxLines,
            keyboardType: widget.keyboardType,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: widget.fieldLabel),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: widget.destructive
              ? FilledButton.styleFrom(
                  backgroundColor: scheme.error, foregroundColor: scheme.onError)
              : null,
          onPressed:
              _valid ? () => Navigator.pop(context, _controller.text.trim()) : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
