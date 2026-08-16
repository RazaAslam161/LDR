import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/auth/widgets/alert_banner.dart';
import 'package:miles/features/auth/widgets/auth_scaffold.dart';
import 'package:miles/features/auth/widgets/labeled_field.dart';

class SignUpPage extends ConsumerStatefulWidget {
  const SignUpPage({super.key});

  @override
  ConsumerState<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends ConsumerState<SignUpPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  bool _loading = false;
  bool _reveal = false;
  String? _error;
  String? _emailError;
  String? _notice;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
      _emailError = null;
      _notice = null;
    });
    try {
      await SupabaseRepository.signUp(
        email: _email.text.trim(),
        password: _password.text,
      );
      setState(() {
        _loading = false;
        // Deliberately ambiguous, and deliberately TRUE in both cases.
        //
        // Supabase answers a signup for an address that already has an account
        // with a success-shaped response, on purpose: saying "that email is
        // taken" turns this form into an oracle anyone can feed addresses to in
        // order to learn who has an account on a private couples app. That
        // property is worth keeping.
        //
        // What was not worth keeping is the old copy, "we sent you a
        // confirmation link", which ASSERTS something that is false for an
        // existing account — so a user who had simply forgotten they had signed
        // up waited for mail that was never coming, with no way to read the
        // screen correctly. This says only what is true either way, and the two
        // routes out are on the screen instead of being guessed at.
        _notice = 'If this address is new, a confirmation link is on its way. '
            'If it already has an account, sign in below — or reset the '
            'password if you have forgotten it.';
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = friendlyAuthError(e);
      });
    }
  }

  /// Sends the reset mail for whatever is typed above, without leaving the page.
  ///
  /// Same non-committal answer as everywhere else — sendPasswordReset does not
  /// report whether the address exists and this must not either.
  Future<void> _resetPassword() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _emailError = 'Enter your email address first.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _emailError = null;
    });
    try {
      await SupabaseRepository.sendPasswordReset(email);
    } catch (_) {
      // Swallowed on purpose: an error here that a success does not produce
      // would say whether the address is registered, which is the whole thing
      // this screen refuses to say.
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _notice = 'If that address has an account, a reset link is on its way.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Begin',
      subtitle: 'Create your account. Invite your partner next.',
      onBack: () => context.go('/'),
      children: [
        LabeledField(
          label: 'Email',
          error: _emailError,
          child: TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _passwordFocus.requestFocus(),
            autofillHints: const [AutofillHints.username],
            // No suggestion strip, and nothing learned into the
            // keyboard's dictionary — a disguised app must not surface
            // its own email back on any other app's keyboard.
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            decoration: const InputDecoration(hintText: 'you@home.com'),
          ),
        ),
        const SizedBox(height: 16),
        LabeledField(
          label: 'Password',
          // The rule, before it can be broken. It used to live only in the
          // greyed-out hint inside the box, which disappears the moment the
          // first character is typed — so the one moment it was legible was
          // the one moment nobody needed it.
          hint: 'At least 8 characters.',
          child: TextField(
            controller: _password,
            focusNode: _passwordFocus,
            obscureText: !_reveal,
            autofillHints: const [AutofillHints.newPassword],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _loading ? null : _submit(),
            decoration: InputDecoration(
              hintText: 'At least 8 characters',
              suffixIcon: IconButton(
                onPressed: () => setState(() => _reveal = !_reveal),
                icon: Icon(_reveal ? Icons.visibility_off : Icons.visibility),
                tooltip: _reveal ? 'Hide password' : 'Show password',
              ),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          AlertBanner(message: _error!),
        ],
        if (_notice != null) ...[
          const SizedBox(height: 16),
          AlertBanner(message: _notice!, tone: AlertTone.info),
          const SizedBox(height: 12),
          // Both exits, shown only once the ambiguous notice is up. The
          // screen otherwise ends at a dead end for exactly the user who
          // needs them: the one who already has an account.
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _loading ? null : () => context.go('/signin'),
                  child: const Text('Sign in'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: _loading ? null : _resetPassword,
                  child: const Text('Reset password'),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create account'),
        ),
        const SizedBox(height: 8),
        AuthSwitchLink(
          prompt: 'Already with us?',
          action: 'Sign in',
          onPressed: _loading ? null : () => context.go('/signin'),
        ),
      ],
    );
  }
}
