import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/error_mapper.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../auth/domain/username.dart';
import '../application/users_providers.dart';
import '../data/users_repository.dart';
import '../domain/app_user.dart';

const minPasswordLength = 8;

String? validatePassword(String value) {
  if (value.length < minPasswordLength) {
    return 'At least $minPasswordLength characters';
  }
  if (value.length > 72) return 'At most 72 characters';
  return null;
}

/// Readable random password (no look-alike characters).
String generatePassword([int length = 10]) {
  const chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789';
  final random = Random.secure();
  return List.generate(
    length,
    (_) => chars[random.nextInt(chars.length)],
  ).join();
}

/// Super Admin → Users → New user.
class CreateUserScreen extends ConsumerStatefulWidget {
  const CreateUserScreen({super.key});

  @override
  ConsumerState<CreateUserScreen> createState() => _CreateUserScreenState();
}

class _CreateUserScreenState extends ConsumerState<CreateUserScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _submitted = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    // After the first attempt, errors update live as the user types.
    if (!_submitted) setState(() => _submitted = true);
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user = await ref
          .read(usersRepositoryProvider)
          .createUser(
            name: _name.text.trim(),
            username: Username.normalize(_username.text),
            password: _password.text,
          );
      ref.invalidate(usersListProvider);
      if (!mounted) return;
      setState(() => _busy = false);
      await _showCreated(user, _password.text);
      if (mounted) context.pop();
    } catch (e, st) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = mapError(e, st).message;
        });
      }
    }
  }

  Future<void> _showCreated(AppUser user, String password) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.elevated,
        title: const Text('User created'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Share these sign-in details with ${user.name}:'),
            const SizedBox(height: AppSpacing.md),
            SelectableText('Username: ${user.username}\nPassword: $password'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(
                  text: 'Username: ${user.username}\nPassword: $password',
                ),
              );
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('Copy & close'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New user')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          autovalidateMode: _submitted
              ? AutovalidateMode.onUserInteraction
              : AutovalidateMode.disabled,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              TextFormField(
                controller: _name,
                enabled: !_busy,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Full name'),
                validator: (v) {
                  final value = (v ?? '').trim();
                  if (value.isEmpty) return 'Enter a name';
                  if (value.length > 80) return 'At most 80 characters';
                  return null;
                },
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _username,
                enabled: !_busy,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: null,
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.next,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9._]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Username',
                  helperText: '3–30 characters: letters, numbers, . and _ (used to sign in)',
                ),
                validator: (v) => Username.isValid(v ?? '')
                    ? null
                    : 'Use 3–30 letters/numbers; . or _ only in the middle',
              ),
              const SizedBox(height: AppSpacing.md),
              // Visible plain field with autofill off: this is someone else's
              // password (the admin shares it), so iOS/Android must not offer
              // to save it to the admin's own keychain.
              TextFormField(
                controller: _password,
                enabled: !_busy,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: null,
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  labelText: 'Password',
                  helperText:
                      'At least $minPasswordLength characters · shown so you can share it',
                ),
                validator: (v) => validatePassword(v ?? ''),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () =>
                            setState(() => _password.text = generatePassword()),
                  icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: const Text('Generate password'),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(_error!, style: const TextStyle(color: AppColors.expense)),
              ],
              const SizedBox(height: AppSpacing.xl),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Create user'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
