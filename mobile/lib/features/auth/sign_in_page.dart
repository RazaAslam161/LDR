import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/auth/widgets/alert_banner.dart';
import 'package:miles/features/auth/widgets/labeled_field.dart';

class SignInPage extends ConsumerStatefulWidget {
  const SignInPage({super.key, this.redirect});
  final String? redirect;

  @override
  ConsumerState<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends ConsumerState<SignInPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  String? _error;

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
    });
    try {
      await SupabaseRepository.signIn(
        email: _email.text.trim(),
        password: _password.text,
      );
      // Deliberately not deciding on /rewrap here. The auth event fires inside
      // signIn and the router sweeps this page away before the Argon2id tail
      // finishes, so `if (mounted)` silently dropped that navigation for the
      // exact cohort that needed it. The router reads CryptoCore.keyless
      // instead — which signIn has just written, and which a cold start reads
      // back from storage.
      if (mounted) context.go(widget.redirect ?? '/app');
    } catch (e) {
      setState(() {
        _loading = false;
        _error = friendlyAuthError(e);
      });
    }
  }

  /// Send a reset link.
  ///
  /// The confirmation is identical whether or not the address has an account —
  /// otherwise this screen becomes a way to find out who is registered.
  Future<void> _forgotPassword() async {
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter your email above first.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await SupabaseRepository.sendPasswordReset(email);
    } catch (_) {
      // Swallowed on purpose — see above.
    }
    if (!mounted) return;
    setState(() => _loading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('If $email has an account, a reset link is on its way.'),
      ),
    );
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
                'Welcome back',
                style: Theme.of(context).textTheme.displayMedium?.copyWith(
                      color: const Color(0xFFFBF8F4),
                    ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Your countdown is waiting.',
                style: TextStyle(color: Color(0x99F5EFE6)),
              ),
              const SizedBox(height: 32),
              LabeledField(
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
              LabeledField(
                label: 'Password',
                child: TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(hintText: '••••••••'),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                AlertBanner(message: _error!),
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
                    : const Text('Sign in'),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _loading ? null : _forgotPassword,
                  child: const Text('Forgot password?',
                      style: TextStyle(color: Color(0x99F5EFE6), fontSize: 13),),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'New here? ',
                    style: TextStyle(color: Color(0x99F5EFE6)),
                  ),
                  GestureDetector(
                    onTap: () => context.go('/signup'),
                    child: const Text(
                      'Create an account',
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
