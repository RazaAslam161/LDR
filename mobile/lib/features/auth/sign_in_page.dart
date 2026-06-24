import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/supabase_repository.dart';
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
      if (mounted) {
        context.go(widget.redirect ?? '/app');
      }
    } catch (e) {
      setState(() {
        _loading = false;
        _error = friendlyAuthError(e);
      });
    }
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
              const SizedBox(height: 16),
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
