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
  String? _passwordError;
  String? _notice;

  /// The address the form was submitted with, once it has been.
  String? _sentTo;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    if (!email.contains('@') || email.startsWith('@') || email.endsWith('@')) {
      setState(() => _emailError = "That doesn't look like an email address.");
      return;
    }
    // Checked here, because nothing else does.
    //
    // The field asks for eight, NewPasswordPage enforces eight, and the server
    // minimum is six — so a seven-character password was accepted at sign-up
    // and then refused at every reset, and the account's own password could not
    // be re-entered on the screen that changes it. It is also the Argon2id
    // input for the escrow wrap key, and leaked-password protection is off on
    // the project, which makes the client the only place anything is asked at
    // all.
    if (_password.text.length < 8) {
      setState(() => _passwordError = 'Use at least 8 characters.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _emailError = null;
      _passwordError = null;
      _notice = null;
    });
    try {
      await SupabaseRepository.signUp(
        email: _email.text.trim(),
        password: _password.text,
      );
      setState(() {
        _loading = false;
        // Supabase answers a signup for an address that already has an account
        // with a success-shaped response, on purpose: saying "that email is
        // taken" turns this form into an oracle anyone can feed addresses to in
        // order to learn who has an account on a private couples app — which is
        // precisely the question this app's disguise, panic gesture and contact
        // pause exist to keep unanswerable. It also does not create a second
        // account; there is no duplicate to worry about, only a silence.
        //
        // So the screen stops trying to resolve it and hands over to
        // [_sentState], which says the one thing that is true either way and
        // offers both ways onward. See the note there.
        _sentTo = email;
        _notice = null;
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
    // Same shape as the sign-up field above. It used to accept anything
    // non-empty and still promise a link, so a typo'd address produced the
    // identical reassurance as a real one.
    if (!email.contains('@') || email.startsWith('@') || email.endsWith('@')) {
      setState(() => _emailError = 'Enter your email address first.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _emailError = null;
    });
    String? failure;
    try {
      await SupabaseRepository.sendPasswordReset(email);
    } catch (e) {
      // Reported, not swallowed. Hiding whether the address is REGISTERED is
      // the property this screen protects; hiding that the request failed is
      // just a lie — GoTrue answers a reset the same way for a known and an
      // unknown address, so a rate limit or a dead socket tells a caller
      // nothing about who has an account.
      failure = friendlyAuthError(e);
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = failure;
      _notice = failure != null
          ? null
          : 'If that address has an account, a reset link is on its way.';
    });
  }

  /// Where the form goes once it has been submitted.
  ///
  /// The screen used to keep the whole form on display and stack a green tick
  /// over it saying something hedged, next to two more buttons — a success
  /// mark, an "if", and three competing things to do, all at once. Whether the
  /// address is new is the one fact this form must not answer out loud, so the
  /// answer belongs where only the person holding the mailbox can read it. Here
  /// there is one instruction and the two ways onward, and nothing claims to
  /// know which of them applies.
  Widget _sentState(BuildContext context, String email) {
    return AuthScaffold(
      title: 'Check your inbox',
      subtitle: email,
      onBack: () => setState(() {
        _sentTo = null;
        _notice = null;
        _error = null;
      }),
      children: [
        const Text(
          'If this address is new here, a confirmation link is on its way. '
          'Open it and you are in.',
        ),
        const SizedBox(height: 12),
        const Text(
          'If it already has an account, nothing was sent — no second account '
          'was made either. Sign in instead, or reset the password.',
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          AlertBanner(message: _error!),
        ],
        if (_notice != null) ...[
          const SizedBox(height: 16),
          AlertBanner(message: _notice!, tone: AlertTone.info),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _loading ? null : () => context.go('/signin'),
          child: const Text('Sign in'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _loading ? null : _resetPassword,
          child: Text(_loading ? 'Sending…' : 'Send a reset link'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final sent = _sentTo;
    if (sent != null) return _sentState(context, sent);
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
          error: _passwordError,
          child: TextField(
            controller: _password,
            focusNode: _passwordFocus,
            obscureText: !_reveal,
            autofillHints: const [AutofillHints.newPassword],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _loading ? null : _submit(),
            decoration: InputDecoration(
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
