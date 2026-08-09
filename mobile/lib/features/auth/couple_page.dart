import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/providers.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_repository.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/surface_panel.dart';
import 'package:miles/core/widgets/glow_button.dart';
import 'package:miles/core/widgets/love_text_field.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/auth/widgets/alert_banner.dart';

/// Deep-link/share format for an invite.
String inviteLinkFor(String code) => 'tethered://join?code=$code';

/// Step 2 of onboarding: connect the two partners with an expiring invite code.
class CouplePage extends ConsumerStatefulWidget {
  const CouplePage({super.key});

  @override
  ConsumerState<CouplePage> createState() => _CouplePageState();
}

class _CouplePageState extends ConsumerState<CouplePage> {
  final _code = TextEditingController();
  bool _loading = false;
  String? _error;
  String? _createdCode;
  DateTime? _expiresAt;

  @override
  void initState() {
    super.initState();
    // Pre-fill from a deep link if we arrived via tethered://join?code=…
    final pending = ref.read(pendingInviteCodeProvider);
    if (pending != null) _code.text = pending;
    _restoreInvite();
  }

  /// Put the user back on their code if they already made one.
  ///
  /// Sharing a code means leaving the app, and leaving the app drops the cover
  /// over everything and destroys this screen. Coming back landed on a blank
  /// create/join form with the code gone — while the invite was still live in
  /// the database and the partner was still holding it. That is how an account
  /// ends up permanently half-paired with no way forward.
  Future<void> _restoreInvite() async {
    try {
      final invite = await SupabaseRepository.activePairingInvite();
      if (invite == null || !mounted) return;
      setState(() {
        _createdCode = invite.code;
        _expiresAt = invite.expiresAt;
      });
    } catch (_) {
      // Offline or a transient failure: fall through to the normal form rather
      // than blocking the screen. Creating a new code still works.
    }
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final invite = await SupabaseRepository.createPairingInvite();
      setState(() {
        _loading = false;
        _createdCode = invite.code;
        _expiresAt = invite.expiresAt;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = friendlyAuthError(e);
      });
    }
  }

  Future<void> _join() async {
    if (_code.text.trim().isEmpty) {
      setState(() => _error = 'Enter the code your partner shared.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await SupabaseRepository.redeemPairingInvite(_code.text);
      await ref.read(sessionProvider.notifier).loadProfile();
      if (mounted) context.go('/app');
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e is StateError ? e.message : e.toString();
      });
    }
  }

  /// The way out.
  ///
  /// The router forces anyone without a couple to '/couple' from every path, so
  /// a user who cannot pair — wrong account, partner never joined, changed
  /// their mind — had no exit at all and no way to reach Settings. That turns a
  /// stalled pairing into a dead account.
  Future<void> _signOut() async {
    setState(() => _loading = true);
    try {
      await FcmService.clearToken();
    } catch (_) {
      // Never block the exit on a push-token cleanup.
    }
    await ref.read(sessionProvider.notifier).signOut();
    if (mounted) context.go('/signin');
  }

  Future<void> _enterApp() async {
    await ref.read(sessionProvider.notifier).loadProfile();
    if (mounted) context.go('/app');
  }

  @override
  Widget build(BuildContext context) {
    // React to a deep link arriving while this screen is open.
    ref.listen<String?>(pendingInviteCodeProvider, (_, next) {
      if (next != null && mounted) setState(() => _code.text = next);
    });

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: EmberBackground(
        child: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: _createdCode != null
                    ? _InviteReveal(
                        code: _createdCode!,
                        expiresAt: _expiresAt,
                        onContinue: _enterApp,
                      )
                    : _ConnectView(
                        codeController: _code,
                        loading: _loading,
                        error: _error,
                        onCreate: _create,
                        onJoin: _join,
                      ),
              ),
              // Always reachable, in both states. This screen is a trap
              // otherwise: the router redirects every other path back here
              // until a couple exists.
              Positioned(
                top: 4,
                right: 4,
                child: TextButton(
                  onPressed: _loading ? null : _signOut,
                  child: const Text('Sign out',
                      style: TextStyle(color: MilesColors.taupe, fontSize: 13)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectView extends StatelessWidget {
  const _ConnectView({
    required this.codeController,
    required this.loading,
    required this.error,
    required this.onCreate,
    required this.onJoin,
  });

  final TextEditingController codeController;
  final bool loading;
  final String? error;
  final VoidCallback onCreate;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 40),
          Text('Connect with your partner',
              style: Theme.of(context).textTheme.displayMedium),
          const SizedBox(height: 8),
          const Text(
            'One of you starts your space and shares the code. '
            'The other joins with it.',
            style: TextStyle(color: MilesColors.taupe, height: 1.5),
          ),
          const SizedBox(height: 32),

          SurfacePanel(
            glow: MilesColors.blush,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Start your space',
                    style: TextStyle(
                        color: MilesColors.cream50,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                const Text("You'll get a code & link to send your partner.",
                    style: TextStyle(color: MilesColors.taupe, fontSize: 13)),
                const SizedBox(height: 16),
                GlowButton(
                  label: 'Create & get a code',
                  color: MilesColors.blush,
                  loading: loading,
                  onPressed: loading ? null : onCreate,
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),
          const Row(children: [
            Expanded(child: Divider(color: Color(0x33D9A86C))),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('or', style: TextStyle(color: MilesColors.faint)),
            ),
            Expanded(child: Divider(color: Color(0x33D9A86C))),
          ]),
          const SizedBox(height: 24),

          LoveTextField(
            label: 'Have a code from your partner?',
            controller: codeController,
            hint: 'CODE',
            textAlign: TextAlign.center,
            maxLength: 8,
            inputFormatters: [
              UpperCaseTextFormatter(),
              FilteringTextInputFormatter.allow(RegExp('[A-Z0-9]')),
            ],
            textStyle: const TextStyle(
                color: MilesColors.cream50, fontSize: 22, letterSpacing: 6),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: loading ? null : onJoin,
            child: const Text('Join'),
          ),

          if (error != null) ...[
            const SizedBox(height: 16),
            AlertBanner(message: error!),
          ],
        ],
      ),
    );
  }
}

/// The "waiting for your partner" moment — meant to feel magical.
class _InviteReveal extends StatelessWidget {
  const _InviteReveal({
    required this.code,
    required this.onContinue,
    this.expiresAt,
  });

  final String code;
  final DateTime? expiresAt;
  final Future<void> Function() onContinue;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(
            child: Text("YOU'RE IN",
                style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 4,
                    color: MilesColors.emberSoft)),
          ),
          const SizedBox(height: 12),
          Text('Share this with your person',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.displaySmall),
          const SizedBox(height: 12),
          const Text(
            "They'll tap Join and enter the code — or open your link. "
            'The moment they join, your space comes alive.',
            textAlign: TextAlign.center,
            style: TextStyle(color: MilesColors.taupe, height: 1.5),
          ),
          const SizedBox(height: 32),
          SurfacePanel(
            glow: MilesColors.blush,
            padding: const EdgeInsets.all(28),
            child: Column(
              children: [
                const Text('YOUR INVITE CODE',
                    style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 3,
                        color: MilesColors.taupe)),
                const SizedBox(height: 12),
                Text(
                  code,
                  style: Theme.of(context).textTheme.displayLarge?.copyWith(
                        letterSpacing: 8,
                        fontWeight: FontWeight.w300,
                      ),
                ),
                if (expiresAt != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Expires ${DateFormat('MMM d, h:mm a').format(expiresAt!)}',
                    style: const TextStyle(
                        fontSize: 11, color: MilesColors.faint),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Copied code: $code')));
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy code'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(
                        ClipboardData(text: inviteLinkFor(code)));
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Invite link copied')));
                  },
                  icon: const Icon(Icons.link, size: 16),
                  label: const Text('Copy link'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          GlowButton(
            label: 'Enter our space',
            color: MilesColors.blush,
            onPressed: () => onContinue(),
          ),
        ],
      ),
    );
  }
}

class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}
