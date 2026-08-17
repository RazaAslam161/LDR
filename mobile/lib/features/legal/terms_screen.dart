import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/glow_button.dart';
import 'package:miles/features/legal/terms_gate.dart';
import 'package:miles/features/legal/terms_text.dart';

/// The terms, either as the gate or as a page you went looking for.
///
/// One screen for both, because two would drift and the one nobody reads is
/// the one that would end up out of date. [readOnly] drops the accept bar and
/// gives the route a way back; the gate has neither on purpose — there is no
/// "not now" here, since the alternative to accepting is not using the app.
/// What the gate DOES keep is a sign-out: acceptance is per account, and
/// someone who signed into the wrong one must be able to leave it without
/// accepting terms on its behalf.
class TermsScreen extends ConsumerStatefulWidget {
  const TermsScreen({super.key, this.readOnly = false});

  final bool readOnly;

  @override
  ConsumerState<TermsScreen> createState() => _TermsScreenState();
}

class _TermsScreenState extends ConsumerState<TermsScreen> {
  bool _busy = false;
  String? _error;

  /// The way out.
  ///
  /// The router forces anyone who has not accepted to '/terms' from every
  /// path, so a user who signed into the WRONG account was trapped accepting
  /// terms for it — or uninstalling. Same door as /couple, for the same
  /// reason.
  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await ref.read(sessionProvider.notifier).signOut();
    } catch (e) {
      // Expected on a bad connection: the server-side revoke needs the
      // network, but the local session is already gone (signOut ends the
      // session in a finally). Funnel to sign-in either way — the alternative
      // is _busy latched true on a screen with no other exit.
      debugPrint('[terms] sign-out revoke failed: ${e.runtimeType}');
    }
    if (mounted) context.go('/signin');
  }

  Future<void> _accept() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await TermsGate.accept();
      // No navigation here. The router's redirect owns where this goes, and
      // TermsGate.accepted is what wakes it — popping as well would race it.
    } catch (e) {
      // accept() has already written the local marker and let them through by
      // the time anything can throw, so this is the record failing to land, not
      // the gate refusing. Say the true thing and leave the door open.
      if (mounted) {
        setState(
          () => _error = "We couldn't file that with the server — "
              "we'll try again next time you're online.",
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MilesColors.night,
      appBar: AppBar(
        title: const Text('Terms of Service'),
        automaticallyImplyLeading: widget.readOnly,
        actions: [
          if (!widget.readOnly)
            TextButton(
              onPressed: _busy ? null : _signOut,
              // The only exit from a screen the router will not let an
              // unaccepted account leave, so it has to be a real target
              // rather than 13px of text in a corner.
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 48),
                foregroundColor: MilesColors.taupe,
              ),
              child: const Text('Sign out'),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                children: const [
                  Text(
                    'Version $milesTermsVersion · $milesTermsUpdated',
                    style: TextStyle(color: MilesColors.faint, fontSize: 12),
                  ),
                  SizedBox(height: 16),
                  Text(
                    milesTermsBody,
                    style: TextStyle(
                      color: MilesColors.cream100,
                      fontSize: 13,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
            if (!widget.readOnly)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                decoration: const BoxDecoration(
                  color: MilesColors.surface1,
                  border: Border(
                      top: BorderSide(color: MilesColors.hairline),),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_error != null) ...[
                      Text(_error!,
                          style: const TextStyle(
                              color: MilesColors.ember, fontSize: 12,),),
                      const SizedBox(height: 10),
                    ],
                    GlowButton(
                      label: 'I agree',
                      loading: _busy,
                      onPressed: _busy ? null : _accept,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
