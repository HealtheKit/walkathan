import 'package:flutter/material.dart';
import 'package:validators/validators.dart';

/// Password input with a show/hide toggle.
class _ObscurableField extends StatefulWidget {
  const _ObscurableField({
    required this.controller,
    required this.label,
    required this.validator,
    this.autofillHints,
    this.textInputAction,
  });

  final TextEditingController? controller;
  final String label;
  final String? Function(String?) validator;
  final Iterable<String>? autofillHints;
  final TextInputAction? textInputAction;

  @override
  State<_ObscurableField> createState() => _ObscurableFieldState();
}

class _ObscurableFieldState extends State<_ObscurableField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      obscureText: _obscured,
      autocorrect: false,
      enableSuggestions: false,
      autofillHints: widget.autofillHints,
      textInputAction: widget.textInputAction,
      decoration: InputDecoration(
        labelText: widget.label,
        prefixIcon: const Icon(Icons.lock_outline),
        suffixIcon: IconButton(
          tooltip: _obscured ? 'Show password' : 'Hide password',
          icon: Icon(
            _obscured
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
          ),
          onPressed: () => setState(() => _obscured = !_obscured),
        ),
      ),
      validator: widget.validator,
    );
  }
}

class ConfirmPasswordFormField extends StatelessWidget {
  const ConfirmPasswordFormField({
    super.key,
    required TextEditingController passwordController,
    required this.labelText,
  }) : _passwordController = passwordController;

  final TextEditingController _passwordController;
  final String labelText;

  @override
  Widget build(BuildContext context) {
    return _ObscurableField(
      controller: null,
      label: 'Confirm password',
      textInputAction: TextInputAction.done,
      validator: (String? value) {
        if (_passwordController.text != value) {
          return 'Passwords not match';
        }
        return null;
      },
    );
  }
}

class PasswordFormField extends StatelessWidget {
  const PasswordFormField({
    super.key,
    required TextEditingController passwordController,
    required this.labelText,
  }) : _passwordController = passwordController;

  final TextEditingController _passwordController;
  final String labelText;

  @override
  Widget build(BuildContext context) {
    return _ObscurableField(
      controller: _passwordController,
      label: 'Password',
      autofillHints: const [AutofillHints.password],
      textInputAction: TextInputAction.next,
      validator: (String? value) {
        if (value == null || value.trim().isEmpty) {
          return 'Password required';
        }
        if (value.trim().length < 6) {
          return 'Password must be at least 6 characters';
        }
        return null;
      },
    );
  }
}

class EmailFormField extends StatelessWidget {
  const EmailFormField({
    super.key,
    required TextEditingController emailController,
  }) : _emailController = emailController;

  final TextEditingController _emailController;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: _emailController,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.next,
      autofillHints: const [AutofillHints.email],
      autocorrect: false,
      decoration: const InputDecoration(
        labelText: 'Email',
        hintText: 'your@email.com',
        prefixIcon: Icon(Icons.mail_outline),
      ),
      validator: (String? value) {
        if (value == null || value.trim().isEmpty) {
          return 'Email required';
        }
        if (!isEmail(value.trim())) {
          return 'Enter a valid email';
        }
        return null;
      },
    );
  }
}

class NameFormField extends StatelessWidget {
  const NameFormField({
    super.key,
    required TextEditingController nameController,
  }) : _nameController = nameController;

  final TextEditingController _nameController;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: _nameController,
      textInputAction: TextInputAction.next,
      textCapitalization: TextCapitalization.words,
      autofillHints: const [AutofillHints.givenName],
      decoration: const InputDecoration(
        labelText: 'Name',
        prefixIcon: Icon(Icons.person_outline),
      ),
      validator: (String? value) {
        if (value == null || value.trim().isEmpty) {
          return 'Name required';
        }
        if (value.trim().length < 2 || value.trim().length > 12) {
          return 'Name must be between 2 and 12 characters long';
        }
        return null;
      },
    );
  }
}

class GenderFormField extends StatelessWidget {
  const GenderFormField({
    super.key,
    required this.genderController,
  });

  final ValueNotifier<String?> genderController;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: genderController,
      builder: (context, selectedGender, _) {
        return DropdownButtonFormField<String>(
          initialValue: selectedGender,
          borderRadius: BorderRadius.circular(12),
          decoration: const InputDecoration(
            labelText: 'Gender',
            prefixIcon: Icon(Icons.wc_outlined),
          ),
          items: const [
            DropdownMenuItem(value: 'male', child: Text('Male')),
            DropdownMenuItem(value: 'female', child: Text('Female')),
            DropdownMenuItem(value: 'other', child: Text('Other')),
          ],
          onChanged: (String? value) {
            genderController.value = value;
          },
          validator: (String? value) {
            if (value == null || value.isEmpty) {
              return 'Please select a gender';
            }
            return null;
          },
        );
      },
    );
  }
}
