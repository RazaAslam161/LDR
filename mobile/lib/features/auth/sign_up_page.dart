import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/auth/auth_errors.dart';

class SignUpPage extends ConsumerStatefulWidget {
  const SignUpPage({super.key});

  @override
  ConsumerState<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends ConsumerState<SignUpPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  String? _error;
  String? _notice;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
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
      setState(() => _error = 'Enter your email address first.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
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
    return Scaffold(
      appBar: AppBar(
        leading: TextButton(
          onPressed: () => context.go('/'),
          child: const Text('Back'),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Text(
                'Begin',
                style: Theme.of(context).textTheme.displayMedium?.copyWith(
                      color: const Color(0xFFFBF8F4),
                    ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Create your account. Invite your partner next.',
                style: TextStyle(color: Color(0x99F5EFE6)),
              ),
              const SizedBox(height: 32),
              _LabeledField(
                label: 'Email',
                child: TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  // No suggestion strip, and nothing learned into the
                  // keyboard's dictionary — a disguised app must not surface
                  // its own email back on any other app's keyboard.
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  decoration: const InputDecoration(hintText: 'you@home.com'),
                ),
              ),
              const SizedBox(height: 16),
              _LabeledField(
                label: 'Password',
                child: TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(
                    hintText: 'At least 8 characters',
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                _AlertBanner(message: _error!),
              ],
              if (_notice != null) ...[
                const SizedBox(height: 16),
                _AlertBanner(message: _notice!, tone: _AlertTone.info),
                const SizedBox(height: 8),
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
              const SizedBox(height: 24),
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
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Already with us? ',
                    style: TextStyle(color: Color(0x99F5EFE6)),
                  ),
                  GestureDetector(
                    onTap: () => context.go('/signin'),
                    child: const Text(
                      'Sign in',
                      style: TextStyle(color: Color(0xFFF4937E)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LabeledField extends StatelessWidget {
  const _LabeledField({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: Color(0x80F5EFE6),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

enum _AlertTone { error, info }

class _AlertBanner extends StatelessWidget {
  const _AlertBanner({required this.message, this.tone = _AlertTone.error});
  final String message;
  final _AlertTone tone;

  @override
  Widget build(BuildContext context) {
    final color = tone == _AlertTone.error
        ? const Color(0xFFEF6F58)
        : const Color(0xFF34D399);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MilesColors.tint(color, 0.1, over: MilesColors.night),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(message, style: TextStyle(color: color, fontSize: 13)),
    );
  }
}
