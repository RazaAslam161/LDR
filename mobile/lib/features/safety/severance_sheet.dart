import 'package:flutter/material.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/hold_to_confirm.dart';

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
/// Play-mandated route out, so neither ever ends up behind the other. The
/// EMERGENCY row is last and subdued on purpose: the ordinary way out is the
/// ceremony, and the row that skips its seven days answers only to the person
/// who can prove they are this phone's owner.
///
/// What deliberately is NOT here: an undo. There is no SnackBarAction anywhere
/// in this file and there must never be one. An "Undo" chip sitting on screen
/// for four seconds after someone leaves is the most dangerous control this
/// app could draw — readable by whoever is standing next to them, tappable by
/// whoever takes the phone.
enum SeveranceOutcome { paused, ended, deleteRequested, unlinkStarted }

Future<SeveranceOutcome?> showSeveranceSheet(
  BuildContext context, {
  required Future<void> Function() onEnd,
  required Future<void> Function() onStartCeremony,
  required Future<bool> Function() confirmIdentity,
}) {
  return showModalBottomSheet<SeveranceOutcome>(
    context: context,
    isScrollControlled: true,
    backgroundColor: MilesColors.surface1,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _SeveranceSheet(
      onEnd: onEnd,
      onStartCeremony: onStartCeremony,
      confirmIdentity: confirmIdentity,
    ),
  );
}

class _SeveranceSheet extends StatelessWidget {
  const _SeveranceSheet({
    required this.onEnd,
    required this.onStartCeremony,
    required this.confirmIdentity,
  });

  final Future<void> Function() onEnd;
  final Future<void> Function() onStartCeremony;
  final Future<bool> Function() confirmIdentity;

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
              'Seven days, visible to both of you. One tap undoes it, '
              'any day.',
              style: TextStyle(color: MilesColors.taupe, fontSize: 12),
            ),
            onTap: () => _openCeremony(context),
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
          // The exit that skips the seven days. Deliberately last, deliberately
          // quiet, and behind proof-of-owner — during a ceremony it is the one
          // control that bypasses the protection, and a phone picked up by the
          // wrong hands must not be able to fire it. The way out itself is
          // never gated: the ceremony above needs no proof at all.
          ListTile(
            leading: const Icon(Icons.bolt_outlined, color: MilesColors.taupe),
            title: const Text(
              'Leave right now',
              style: TextStyle(color: MilesColors.taupe),
            ),
            subtitle: const Text(
              'No waiting period. Only you can confirm this is you.',
              style: TextStyle(color: MilesColors.taupe, fontSize: 12),
            ),
            onTap: () => _openEmergency(context),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
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

  Future<void> _openEmergency(BuildContext context) async {
    if (!await confirmIdentity()) return;
    if (!context.mounted) return;
    await _openEnd(context);
  }

  Future<void> _openEnd(BuildContext context) async {
    final navigator = Navigator.of(context);
    final ended = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: MilesColors.surface1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _EndSheet(onEnd: onEnd),
    );
    if (ended ?? false) navigator.pop(SeveranceOutcome.ended);
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
            // copy never was. Seven days is unlink_start()'s interval; the
            // one-tap cancel is unlink_cancel(); the note is
            // unlink_write_note(); what happens at the end is leave_couple().
            const Text(
              'A seven-day unlinking begins, and they will see it begin. '
              'Both of you keep the app, the messages and the calls for the '
              'whole week — and one tap from you brings everything back, '
              'any day.',
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
              'If the week passes, the unlink completes: what the two of you '
              'made together is kept for 30 days and then erased for good. '
              'Your own account and your private vault are untouched.',
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
            Row(
              children: [
                TextButton(
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  child: const Text(
                    'Not now',
                    style: TextStyle(color: MilesColors.taupe),
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => Navigator.pop(context, 'pause'),
                  child: const Text(
                    'Pause instead',
                    style: TextStyle(color: MilesColors.gilt),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: MilesColors.danger,
                  ),
                  onPressed: _busy ? null : _begin,
                  child: const Text('Begin'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EndSheet extends StatefulWidget {
  const _EndSheet({required this.onEnd});

  final Future<void> Function() onEnd;

  @override
  State<_EndSheet> createState() => _EndSheetState();
}

class _EndSheetState extends State<_EndSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _confirm() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onEnd();
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      // The same string the report and pause sheets already use. A fourth
      // wording for one failure is how a user learns to distrust all of them.
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
            // Every sentence is checked against the code. The dialog this
            // replaces promised private data was "preserved" and that it
            // "cannot be undone", and the app's own FAQ said the opposite of
            // the second one. Saying less, accurately, is the fix.
            const Text(
              'This takes effect immediately and for both of you. From the '
              'moment you confirm, neither phone can open the messages, '
              'photos or anything else the two of you shared. Nothing is sent '
              'to them and nothing announces it.',
              style: TextStyle(
                color: MilesColors.taupe,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Your own account is untouched, and so is your private vault — '
              'it was never held under the shared key.',
              style: TextStyle(
                color: MilesColors.taupe,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'What the two of you made together is kept for 30 days and then '
              'erased for good.',
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
            Row(
              children: [
                TextButton(
                  onPressed: _busy ? null : () => Navigator.pop(context, false),
                  child: const Text(
                    'Not now',
                    style: TextStyle(color: MilesColors.taupe),
                  ),
                ),
                const SizedBox(width: 8),
                // Expanded, not a bare width. A Row child sized with
                // Size.fromHeight resolves its width to double.infinity and
                // throws — the same trap the gallery hit.
                Expanded(
                  child: HoldToConfirm(
                    label: 'Hold to end',
                    holdingLabel: 'Ending…',
                    onConfirmed: _busy ? null : _confirm,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
