import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/supabase_repository.dart';
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
        _notice = 'Check your inbox — we sent you a confirmation link.';
      });
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
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(message, style: TextStyle(color: color, fontSize: 13)),
    );
  }
}
