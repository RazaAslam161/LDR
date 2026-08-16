import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/auth/widgets/alert_banner.dart';
import 'package:miles/features/auth/widgets/auth_scaffold.dart';
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
  final _passwordFocus = FocusNode();
  bool _loading = false;
  bool _sendingReset = false;
  bool _reveal = false;
  String? _error;
  String? _emailError;

  /// When the last reset mail was requested, so a second tap cannot spend the
  /// first link.
  ///
  /// Static, and it has to be. Reading the mail means leaving the app, which
  /// raises the disguise cover — and the cover REPLACES the router subtree, so
  /// this State is destroyed every single time. A per-widget field reset itself
  /// on exactly the trip the throttle exists to survive.
  static DateTime? _lastResetAt;

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
      // Against the field it is about, not in the form-level banner at the
      // bottom: the thing to correct is the email box, and this is the one
      // message on the screen that names a specific input.
      setState(() => _emailError = 'Enter your email above first.');
      return;
    }
    // A second request does not send a second mail — it spends the first.
    //
    // gotrue writes a fresh PKCE verifier to one shared key before it issues
    // /recover, so the link already in the inbox stops matching the moment
    // another request goes out, and the server's own per-address limit is one a
    // minute. Both taps used to print the same cheerful confirmation, so the
    // ordinary impatient user ended up with an inbox of links where only the
    // last could work and no way to know it.
    final since = _lastResetAt;
    if (since != null && DateTime.now().difference(since).inSeconds < 60) {
      setState(
        () => _error = 'A link is already on its way. Give it a minute before '
            'asking for another — a new one stops the first from working.',
      );
      return;
    }
    setState(() {
      _sendingReset = true;
      _error = null;
      _emailError = null;
    });
    String? failure;
    try {
      await SupabaseRepository.sendPasswordReset(email);
      _lastResetAt = DateTime.now();
    } catch (e) {
      // Still says nothing about whether the address is registered — GoTrue
      // answers a reset for an unknown address exactly as it answers a known
      // one, so a rate limit or a dead socket is not an oracle. Reporting the
      // failure was never the leak; only "no such user" would be, and that is
      // not a thing this endpoint says.
      failure = friendlyAuthError(e);
    }
    if (!mounted) return;
    setState(() {
      _sendingReset = false;
      _error = failure;
    });
    if (failure != null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('If $email has an account, a reset link is on its way.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Welcome back',
      subtitle: 'Your countdown is waiting.',
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
            // A password manager cannot fill a field that does not say what it
            // holds, and a couples app is exactly where people use one. This is
            // the `autocomplete` attribute of the mobile world.
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
          child: TextField(
            controller: _password,
            focusNode: _passwordFocus,
            obscureText: !_reveal,
            autofillHints: const [AutofillHints.password],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _loading ? null : _submit(),
            decoration: InputDecoration(
              hintText: '••••••••',
              // Typing a password blind on a phone keyboard is how people get
              // locked out of an account they know the password to.
              suffixIcon: IconButton(
                onPressed: () => setState(() => _reveal = !_reveal),
                icon: Icon(_reveal ? Icons.visibility_off : Icons.visibility),
                tooltip: _reveal ? 'Hide password' : 'Show password',
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          // Its own progress, and its own flag. Both actions used to share
          // `_loading`, so asking for a reset link spun the Sign in button and
          // the only feedback for the tap you actually made was a SnackBar you
          // were no longer looking at, having gone to your inbox.
          child: TextButton(
            onPressed: _loading || _sendingReset ? null : _forgotPassword,
            style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
            child: Text(_sendingReset ? 'Sending…' : 'Forgot password?'),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          AlertBanner(message: _error!),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _loading || _sendingReset ? null : _submit,
          child: _loading
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Sign in'),
        ),
        const SizedBox(height: 8),
        AuthSwitchLink(
          prompt: 'New here?',
          action: 'Create an account',
          onPressed:
              _loading || _sendingReset ? null : () => context.go('/signup'),
        ),
      ],
    );
  }
}
