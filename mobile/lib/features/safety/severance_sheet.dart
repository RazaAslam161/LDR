import 'package:flutter/material.dart';
import 'package:miles/core/ui/theme.dart';

/// The ways out, at every size, on one sheet.
///
/// It lives in features/safety rather than features/settings on purpose: the
/// rule stated at the top of safety_sheets.dart applies here in full. Every
/// label is neutral, nothing names the partner in a heading, and nothing here
/// is phrased so that reading it over a shoulder tells you what was about to
/// happen.
///
/// The ordering is the whole design. Ending the connection is not buried, not
/// slower and not one tap further away than it was before — it is the second
/// row, always drawn, never gated. What sits above it is what most people
/// actually want at the moment they reach for it; what sits below it is the
/// Play-mandated route out, so neither ever ends up behind the other.
///
/// There is NO immediate-exit row. "Leave right now" was removed on 2026-08-29
/// by the owner: the ritual IS the way out, and a second door that skipped its
/// window meant the sheet offered two endings with different rules and a
/// proof-of-owner prompt that said nothing when it failed. One ending, one set
/// of rules.
///
/// What deliberately is NOT here: an undo. There is no SnackBarAction anywhere
/// in this file and there must never be one. An "Undo" chip sitting on screen
/// for four seconds after someone leaves is the most dangerous control this
/// app could draw — readable by whoever is standing next to them, tappable by
/// whoever takes the phone.
enum SeveranceOutcome { paused, ended, deleteRequested, unlinkStarted }

/// [hasPartner] is the load-bearing argument, not a cosmetic one.
///
/// Every row on this sheet except deletion needs somebody on the other end.
/// `mute_partner` opens with `if v_partner is null then raise exception
/// 'no partner'`, and `unlink_start` cannot begin a ceremony with nobody to
/// hold the other side of it. Offered unconditionally, both rows reached a
/// server that refused them and died in a generic catch — which is exactly
/// what "I pressed the 1 hour button and nothing happened" is.
///
/// A couple of ONE is a real state this app can be in: a dissolution can leave
/// one member standing, and create_pairing_invite mints a couple for a caller
/// who has none. So the sheet asks whether there is a partner and offers only
/// what can actually work.
Future<SeveranceOutcome?> showSeveranceSheet(
  BuildContext context, {
  required Future<void> Function() onStartCeremony,
  required bool hasPartner,
}) {
  return showModalBottomSheet<SeveranceOutcome>(
    context: context,
    isScrollControlled: true,
    backgroundColor: MilesColors.surface1,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _SeveranceSheet(
      onStartCeremony: onStartCeremony,
      hasPartner: hasPartner,
    ),
  );
}

class _SeveranceSheet extends StatelessWidget {
  const _SeveranceSheet({
    required this.onStartCeremony,
    required this.hasPartner,
  });

  final Future<void> Function() onStartCeremony;
  final bool hasPartner;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Text(
              'Take a step back',
              style: TextStyle(
                color: MilesColors.cream50,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              'Different sizes of the same thing. Nothing here tells anyone '
              'anything unless it says so.',
              style: TextStyle(
                color: MilesColors.taupe,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
          if (hasPartner) ...[
            ListTile(
              leading: const Icon(
                Icons.notifications_off_outlined,
                color: MilesColors.gilt,
              ),
              title: const Text(
                'Pause notifications',
                style: TextStyle(color: MilesColors.cream50),
              ),
              subtitle: const Text(
                'Quiet for a while. Nothing is told, nothing ends.',
                style: TextStyle(color: MilesColors.taupe, fontSize: 12),
              ),
              // Popped, not pushed from here. Opening the pause sheet on this
              // sheet's own context after popping it pushes onto a route that is
              // already gone; the caller owns what happens next, exactly as it
              // does for the deletion row.
              onTap: () => Navigator.pop(context, SeveranceOutcome.paused),
            ),
            ListTile(
              leading: const Icon(Icons.link_off, color: MilesColors.danger),
              title: const Text(
                'End the connection',
                style: TextStyle(color: MilesColors.cream50),
              ),
              subtitle: const Text(
                'A day apart, and a way back. Both of you step out of the '
                'app while it runs.',
                style: TextStyle(color: MilesColors.taupe, fontSize: 12),
              ),
              onTap: () => _openCeremony(context),
            ),
          ] else
            // Nobody on the other end. Pausing notifications from a partner
            // who is not there, and beginning a goodbye with nobody to read
            // it, are both refused by the server — unlink_start() raises
            // no_partner since 20260830120000 — so neither is offered.
            // What IS offered is the way out of the empty connection, because
            // this state otherwise has no exit from this screen at all.
            ListTile(
              leading: const Icon(Icons.link_off, color: MilesColors.danger),
              title: const Text(
                'Leave this connection',
                style: TextStyle(color: MilesColors.cream50),
              ),
              subtitle: const Text(
                'Nobody is on the other side of it any more. There is nobody '
                'to wait for, so this ends it now and frees you to connect '
                'again.',
                style: TextStyle(color: MilesColors.taupe, fontSize: 12),
              ),
              onTap: () => _confirmLeaveEmpty(context),
            ),
          // Last, and never behind the row above it. Play requires the
          // deletion route to stay reachable, and someone who came here to
          // delete an account must not have to end a connection first.
          ListTile(
            leading: const Icon(Icons.delete_outline, color: MilesColors.danger),
            title: const Text(
              'Delete your account',
              style: TextStyle(color: MilesColors.cream50),
            ),
            subtitle: const Text(
              'Everything recorded against your account alone.',
              style: TextStyle(color: MilesColors.taupe, fontSize: 12),
            ),
            onTap: () =>
                Navigator.pop(context, SeveranceOutcome.deleteRequested),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  /// Leaving a connection that has nobody in it. Confirmed rather than
  /// instant — it is still an ending, and the row sits where "End the
  /// connection" sits — but there is no window to offer, because a waiting
  /// period exists so the other person can object and there is no other
  /// person.
  ///
  /// Popped upward like every other row: the caller owns what follows, and
  /// leaveCouple must run in the caller's context so the local wipe and the
  /// profile reload keep the order settings_screen pins them in.
  Future<void> _confirmLeaveEmpty(BuildContext context) async {
    final navigator = Navigator.of(context);
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: const Text(
          'Leave this connection?',
          style: TextStyle(color: MilesColors.cream50),
        ),
        content: const Text(
          'It has no one else in it. Leaving clears it from this account so '
          'you can connect again.',
          style: TextStyle(color: MilesColors.taupe),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Leave',
              style: TextStyle(color: MilesColors.danger),
            ),
          ),
        ],
      ),
    );
    if (sure ?? false) navigator.pop(SeveranceOutcome.ended);
  }

  Future<void> _openCeremony(BuildContext context) async {
    final navigator = Navigator.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: MilesColors.surface1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CeremonySheet(onStartCeremony: onStartCeremony),
    );
    // Popped upward, never pushed from here — the caller owns what follows,
    // exactly as it does for the pause and deletion rows.
    if (choice == 'begin') navigator.pop(SeveranceOutcome.unlinkStarted);
    if (choice == 'pause') navigator.pop(SeveranceOutcome.paused);
  }

}

/// The ceremony's front door: what beginning one means, said plainly, with
/// the pause offramp beside it — most people reaching for the door want
/// distance, not deletion.
class _CeremonySheet extends StatefulWidget {
  const _CeremonySheet({required this.onStartCeremony});

  final Future<void> Function() onStartCeremony;

  @override
  State<_CeremonySheet> createState() => _CeremonySheetState();
}

class _CeremonySheetState extends State<_CeremonySheet> {
  bool _busy = false;
  String? _error;

  Future<void> _begin() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onStartCeremony();
      if (mounted) Navigator.pop(context, 'begin');
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = "That didn't go through. Try again.";
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'End the connection?',
              style: TextStyle(
                color: MilesColors.cream50,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            // Every sentence checked against the code, as the old dialog's
            // copy never was. The one day and the fifteen-minute gate are both
            // intervals inside unlink_start. The way back is unlink_cancel,
            // deliberately ungated on the server, so it works the moment the
            // button appears. The note is unlink_write_note. What closes it at
            // the end is dissolve_couple, reached either by unlink_execute or
            // by the unlink-expire-due job.
            //
            // The copy this replaces promised that both of them keep the app,
            // the messages and the calls for the whole week. Every clause of
            // that is now false. The ritual TAKES the app, and saying
            // otherwise on the one screen somebody reads before deciding is
            // the worst place in the product to be wrong.
            const Text(
              'The app closes for both of you for one day. They are told you '
              'need space — not that you asked to unlink — and they can write '
              'to you. After fifteen minutes a Re-link button appears on your '
              'screen; one tap and none of this happened.',
              style: TextStyle(
                color: MilesColors.taupe,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'They can write you something. You will see it beside the '
              'button that undoes this.',
              style: TextStyle(
                color: MilesColors.taupe,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'If the day passes with nothing changed, the unlink completes: '
              'your gallery stays with both of you, read-only, and the rest is '
              'kept but can no longer be opened. Your own account and your '
              'private vault are untouched.',
              style: TextStyle(
                color: MilesColors.taupe,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(
                  color: MilesColors.danger,
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: 18),
            // Begin gets its own full-width row, and the two ways out share
            // the one below it.
            //
            // This was a single Row of all three with a Spacer, and on a
            // 360dp phone — the OnePlus 8, at font scale 1.0 — the three
            // intrinsic widths did not fit. A RenderFlex overflow collapses
            // the Spacer to zero and lays the LAST child out past the right
            // edge, where no pointer event can reach it. In a release build
            // that paints nothing and logs nothing, so the only symptom was
            // the owner tapping "End the connection" and reporting that the
            // whole feature did nothing. It was the one control that starts
            // the ceremony, and it was off the screen.
            //
            // Nothing here has an intrinsic width that can exceed the sheet:
            // the button stretches, and the pair below WRAPS rather than
            // overflowing when the text scale grows.
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: MilesColors.danger,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: _busy ? null : _begin,
                  child: const Text('Begin'),
                ),
                const SizedBox(height: 4),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: _busy ? null : () => Navigator.pop(context),
                      child: const Text(
                        'Not now',
                        style: TextStyle(color: MilesColors.taupe),
                      ),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.pop(context, 'pause'),
                      child: const Text(
                        'Pause instead',
                        style: TextStyle(color: MilesColors.gilt),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
