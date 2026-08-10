import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/glow_button.dart';
import 'package:miles/core/widgets/love_text_field.dart';

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
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final pw = _password.text;
    if (pw.length < 8) {
      setState(() => _error = 'Use at least 8 characters.');
      return;
    }
    if (pw != _confirm.text) {
      setState(() => _error = 'Those two do not match.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
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
          _error = 'Could not update your password. The link may have '
              'expired — request a new one.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: EmberBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('Choose a new password',
                    style: TextStyle(
                        color: MilesColors.cream50,
                        fontSize: 26,
                        fontWeight: FontWeight.w700,),),
                const SizedBox(height: 24),
                LoveTextField(
                  controller: _password,
                  label: 'New password',
                  obscureText: true,
                ),
                const SizedBox(height: 14),
                LoveTextField(
                  controller: _confirm,
                  label: 'Confirm password',
                  obscureText: true,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: MilesColors.ember),),
                ],
                const SizedBox(height: 24),
                GlowButton(
                  label: _busy ? 'Saving…' : 'Save password',
                  onPressed: _busy ? null : _save,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
