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
/// Play-mandated route out, so neither ever ends up behind the other.
///
/// What deliberately is NOT here: an undo. There is no SnackBarAction anywhere
/// in this file and there must never be one. An "Undo" chip sitting on screen
/// for four seconds after someone leaves is the most dangerous control this
/// app could draw — readable by whoever is standing next to them, tappable by
/// whoever takes the phone.
enum SeveranceOutcome { paused, ended, deleteRequested }

Future<SeveranceOutcome?> showSeveranceSheet(
  BuildContext context, {
  required Future<void> Function() onEnd,
}) {
  return showModalBottomSheet<SeveranceOutcome>(
    context: context,
    isScrollControlled: true,
    backgroundColor: MilesColors.surface1,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _SeveranceSheet(onEnd: onEnd),
  );
}

class _SeveranceSheet extends StatelessWidget {
  const _SeveranceSheet({required this.onEnd});

  final Future<void> Function() onEnd;

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
              'Immediate, and for both of you. Nothing is sent to them.',
              style: TextStyle(color: MilesColors.taupe, fontSize: 12),
            ),
            onTap: () => _openEnd(context),
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
