import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/features/auth/widgets/alert_banner.dart';
import 'package:miles/features/auth/widgets/auth_scaffold.dart';
import 'package:miles/features/auth/widgets/labeled_field.dart';

/// Where a password-reset link lands.
///
/// Supabase's recovery link signs the user in with a temporary session and
/// emits an AuthChangeEvent.passwordRecovery. Until now there was nowhere for
/// that to go: no redirect was requested, so the mail pointed at the project's
/// default Site URL (http://localhost:3000) and opened "localhost refused to
/// connect" on the phone. Even had it opened the app, no screen existed to set
/// the new password — so a forgotten password meant a dead account.
class NewPasswordPage extends ConsumerStatefulWidget {
  const NewPasswordPage({super.key});

  @override
  ConsumerState<NewPasswordPage> createState() => _NewPasswordPageState();
}

class _NewPasswordPageState extends ConsumerState<NewPasswordPage> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _confirmFocus = FocusNode();
  bool _busy = false;
  bool _reveal = false;

  /// Which field is wrong, rather than one line under both of them. "Those two
  /// do not match" printed centrally under a pair of identical-looking boxes
  /// does not say which one to retype.
  String? _passwordError;
  String? _confirmError;
  String? _formError;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final pw = _password.text;
    if (pw.length < 8) {
      setState(() {
        _passwordError = 'Use at least 8 characters.';
        _confirmError = null;
      });
      return;
    }
    if (pw != _confirm.text) {
      setState(() {
        _passwordError = null;
        _confirmError = 'Those two do not match.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _passwordError = null;
      _confirmError = null;
      _formError = null;
    });
    try {
      await SupabaseRepository.updatePassword(pw);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password updated 💛')),
      );
      context.go('/app');
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          // The recovery session is short-lived; saying so beats a bare
          // "something went wrong" when the link has simply gone stale.
          _formError = 'Could not update your password. The link may have '
              'expired — request a new one.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Choose a new password',
      subtitle: 'This replaces the old one everywhere you are signed in.',
      centred: true,
      children: [
        LabeledField(
          label: 'New password',
          hint: 'At least 8 characters.',
          error: _passwordError,
          child: TextField(
            controller: _password,
            obscureText: !_reveal,
            autofillHints: const [AutofillHints.newPassword],
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _confirmFocus.requestFocus(),
            decoration: InputDecoration(
              suffixIcon: IconButton(
                onPressed: () => setState(() => _reveal = !_reveal),
                icon: Icon(_reveal ? Icons.visibility_off : Icons.visibility),
                tooltip: _reveal ? 'Hide password' : 'Show password',
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        LabeledField(
          label: 'Confirm password',
          error: _confirmError,
          child: TextField(
            controller: _confirm,
            focusNode: _confirmFocus,
            obscureText: !_reveal,
            autofillHints: const [AutofillHints.newPassword],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _busy ? null : _save(),
          ),
        ),
        if (_formError != null) ...[
          const SizedBox(height: 16),
          AlertBanner(message: _formError!),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save password'),
        ),
      ],
    );
  }
}
