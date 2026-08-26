import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/hold_to_confirm.dart';
import 'package:miles/features/safety/severance_state.dart';

/// The only door back, and the only way to shut it for good.
///
/// It opens from a row on the pairing screen that is drawn UNCONDITIONALLY,
/// whether or not anything is recoverable. That is the whole disclosure
/// argument: a control that appears only when a window is open announces the
/// window to anyone holding the phone, and the ruling on this was that nothing
/// announces an unpair. A control that is always there announces nothing, and
/// what it says when tapped is the first anyone learns.
///
/// The other person is told a window exists only when this account actually
/// asks — a deliberate act, and one the server caps at a single ask each.
Future<void> showReconnectSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: MilesColors.surface1,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _ReconnectSheet(),
  );
}

class _ReconnectSheet extends StatefulWidget {
  const _ReconnectSheet();

  @override
  State<_ReconnectSheet> createState() => _ReconnectSheetState();
}

class _ReconnectSheetState extends State<_ReconnectSheet> {
  bool _busy = false;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Re-read on open rather than trusting whatever loadProfile left behind:
    // the other one may have answered, or withdrawn, or ended it for good
    // since this screen was built.
    SeveranceState.load().whenComplete(() {
      if (mounted) setState(() => _loading = false);
    });
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await SeveranceState.load();
      if (!mounted) return;
      // Both resolved BEFORE the pop. Reading ScaffoldMessenger.of(context)
      // afterwards asks a route that no longer exists.
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      if (done != null) {
        messenger.showSnackBar(SnackBar(content: Text(done)));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _readable(e);
          _busy = false;
        });
      }
    }
  }

  /// The server's error strings are contracts, not prose. Each one is turned
  /// into a sentence that says what happened without saying anything about the
  /// other person's choices.
  String _readable(Object e) {
    final raw = e.toString();
    if (raw.contains('declined')) {
      return 'That was already answered. You can’t ask again.';
    }
    if (raw.contains('already_requested')) {
      return 'There’s already an open request here.';
    }
    if (raw.contains('only your partner can confirm')) {
      return 'Only the other person can agree to this.';
    }
    if (raw.contains('partner_has_moved_on') ||
        raw.contains('no_restorable_couple')) {
      return 'This can’t be brought back any more.';
    }
    if (raw.contains('already_paired')) {
      return 'You’re already connected.';
    }
    return "That didn't go through. Try again.";
  }

  /// Confirming is the one action here that completes a restoration on its own,
  /// so it is the one that asks for the password. A person who picks up an
  /// unlocked phone can tap it otherwise, and the request waiting on it may be
  /// their own.
  ///
  /// Asking is NOT gated: it cannot restore anything without the other one.
  /// Erasing is NOT gated either, and that is the important one — the way out
  /// must never be slower than the way back.
  Future<bool> _confirmIsReallyYou() async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _PasswordDialog(),
    );
    if (password == null || password.isEmpty) return false;
    if (!await SupabaseRepository.reauthenticate(password)) {
      if (mounted) {
        setState(() => _error = "That isn't your password. Nothing changed.");
      }
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final held = SeveranceState.held.value;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _loading
              ? const [
                  SizedBox(height: 8),
                  Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(height: 24),
                ]
              : (held == null || held.expired)
                  ? _nothing()
                  : _something(held),
        ),
      ),
    );
  }

  // ── Nothing to bring back ────────────────────────────────────────────────
  // Also what somebody sees who never had a couple at all, and what somebody
  // sees after the other one ended it for good. One answer, three causes: the
  // server returns the same null for all of them and this must not undo that.
  List<Widget> _nothing() => [
        const Text('Reconnecting',
            style: TextStyle(
                color: MilesColors.cream50,
                fontSize: 16,
                fontWeight: FontWeight.w600,),),
        const SizedBox(height: 10),
        const Text(
          'There’s nothing here to bring back.',
          style:
              TextStyle(color: MilesColors.taupe, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 10),
        const Text(
          'Connecting with someone is the same as the first time: one of you '
          'starts a space and shares the code, the other enters it.',
          style:
              TextStyle(color: MilesColors.taupe, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close',
                style: TextStyle(color: MilesColors.taupe),),
          ),
        ),
      ];

  // ── There is something ───────────────────────────────────────────────────
  List<Widget> _something(HeldHistory held) {
    final when = DateFormat('d MMMM').format(held.purgeAt.toLocal());
    return [
      Text('Held until $when',
          style: const TextStyle(
              color: MilesColors.cream50,
              fontSize: 16,
              fontWeight: FontWeight.w600,),),
      const SizedBox(height: 10),
      const Text(
        'What the two of you made before is kept until then, and erased after. '
        'Bringing it back needs both of you to agree.',
        style: TextStyle(color: MilesColors.taupe, fontSize: 13, height: 1.5),
      ),
      const SizedBox(height: 16),
      ..._action(held),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!,
            style: const TextStyle(color: MilesColors.danger, fontSize: 12),),
      ],
      // Offered only when this phone genuinely cannot read what they wrote.
      // The ceremony needs the other one on a call reading six digits aloud,
      // so it is worth showing exactly when there is somebody left to call —
      // the same condition the router opens /rewrap on.
      if (CryptoCore.keyless.value) ...[
        const SizedBox(height: 16),
        const Text(
          'This phone can’t open what the two of you wrote. They can hand the '
          'key back over a call, while there is still something to hand back.',
          style: TextStyle(color: MilesColors.taupe, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 10),
        OutlinedButton(
          // push, never go: go replaces the stack, and this screen must keep
          // its way back to the sheet and to the pairing page behind it.
          onPressed: _busy ? null : () => context.push('/rewrap'),
          child: const Text('Recover your history'),
        ),
      ],
      const SizedBox(height: 20),
      const Divider(color: Color(0x33D9A86C)),
      const SizedBox(height: 12),
      const Text('Erase it now instead?',
          style: TextStyle(
              color: MilesColors.cream50,
              fontSize: 14,
              fontWeight: FontWeight.w600,),),
      const SizedBox(height: 6),
      const Text(
        'This erases what the two of you made, for both of you, straight away. '
        'It cannot be undone. Your own account and your private vault are not '
        'affected.',
        style: TextStyle(color: MilesColors.taupe, fontSize: 12, height: 1.5),
      ),
      const SizedBox(height: 12),
      // No password, no second sheet, no delay. Somebody who needs this needs
      // it to be the fastest thing on the screen.
      HoldToConfirm(
        label: 'Hold to erase',
        holdingLabel: 'Erasing…',
        onConfirmed: _busy
            ? null
            : () => _run(SupabaseRepository.leaveCouplePermanently,
                done: 'That’s gone.',),
      ),
    ];
  }

  /// Exactly one primary action, decided by whose turn it is.
  List<Widget> _action(HeldHistory held) {
    if (held.awaitingMe ?? false) {
      return [
        const Text('They’ve asked to reconnect.',
            style: TextStyle(color: MilesColors.cream50, fontSize: 14),),
        const SizedBox(height: 12),
        Row(
          children: [
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(SupabaseRepository.coupleRestoreCancel,
                      done: 'Answered.',),
              child: const Text('No',
                  style: TextStyle(color: MilesColors.taupe),),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                style:
                    FilledButton.styleFrom(backgroundColor: MilesColors.ember),
                onPressed: _busy
                    ? null
                    : () async {
                        // reauthenticate() signs in again, which fires
                        // signedIn -> loadProfile(). Same account, same
                        // auth.uid(), so the confirm below is unaffected; the
                        // escrow prompt accepts the same side effect.
                        if (!await _confirmIsReallyYou()) return;
                        await _run(SupabaseRepository.coupleRestoreConfirm,
                            done: 'You’re connected again.',);
                      },
                child: const Text('Yes, reconnect'),
              ),
            ),
          ],
        ),
      ];
    }

    if (held.waitingOnThem) {
      return [
        const Text('You’ve asked. It’s with them now.',
            style: TextStyle(color: MilesColors.cream50, fontSize: 14),),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _busy
              ? null
              : () => _run(SupabaseRepository.coupleRestoreCancel,
                  done: 'Withdrawn.',),
          child: const Text('Withdraw'),
        ),
      ];
    }

    if (held.declined && (held.requestIsMine ?? false)) {
      // Final, and said once without editorialising about it.
      return [
        const Text('That was answered. You can’t ask again.',
            style: TextStyle(color: MilesColors.taupe, fontSize: 14),),
      ];
    }

    return [
      FilledButton(
        style: FilledButton.styleFrom(backgroundColor: MilesColors.ember),
        onPressed: _busy
            ? null
            : () => _run(SupabaseRepository.coupleRestoreRequest,
                done: 'Asked.',),
        child: const Text('Ask to reconnect'),
      ),
    ];
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: MilesColors.surface1,
      title: const Text('Your password',
          style: TextStyle(color: MilesColors.cream50, fontSize: 16),),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Just to be sure it’s you.',
              style: TextStyle(color: MilesColors.taupe, fontSize: 13),),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            obscureText: true,
            autofocus: true,
            style: const TextStyle(color: MilesColors.cream50),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel',
              style: TextStyle(color: MilesColors.taupe),),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: MilesColors.ember),
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}
