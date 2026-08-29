import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/couple_key.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/services/server_clock.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/unlink/unlink_quotes.dart';
import 'package:miles/features/unlink/unlink_repository.dart';
import 'package:miles/features/unlink/unlink_state.dart';

/// The ceremony's one screen, worn differently by its two people.
///
/// The INITIATOR lives here: a quiet page with one love quote, the days
/// remaining, whatever their partner wrote for them, and one large Re-link
/// button — cancelling is always one tap, any day. The PARTNER gets the
/// mirror: the same quote, the clock, a place to write the one note that
/// appears on the initiator's screen, and Accept for the mutual fast path.
/// Nothing here blocks anybody; the week exists so two people keep talking,
/// which is why "continue to app" is always present and chat keeps working.
class UnlinkScreen extends ConsumerStatefulWidget {
  const UnlinkScreen({super.key});

  @override
  ConsumerState<UnlinkScreen> createState() => _UnlinkScreenState();
}

/// Where the note has got to on THIS phone. Four states, because a nullable
/// string only has three and the screen needs all four.
///
/// "Not loaded yet", "there is none" and "there is one and this phone cannot
/// open it" were all `_note == null`, and the two halves of the screen read
/// that null differently: the card required a non-null before it rendered
/// anything, while the editor opened over it and seeded itself with `''` — so
/// a Save landed `unlink_write_note(null, null)` and cleared a note the author
/// could still see the button for. Separating the states is what makes that
/// unrepresentable rather than merely unlikely.
enum _NoteLoad { pending, absent, open, sealed }

/// Reported rather than thrown: the couple key would not derive, so there is
/// nothing to seal the note with. Its own type so the field can COUNT it apart
/// from a failed RPC — this is the keyless state already behind the chat
/// decrypt reports, and on this route it is the difference between "the server
/// said no" and "this phone never unlocked your side".
class _NoteKeyUnavailable implements Exception {
  const _NoteKeyUnavailable();

  @override
  String toString() => 'couple key unavailable for the unlink note';
}

class _UnlinkScreenState extends ConsumerState<UnlinkScreen> {
  Timer? _tick;
  bool _busy = false;
  String? _note;
  _NoteLoad _noteLoad = _NoteLoad.pending;

  /// What the author typed, held from Save until the write LANDS.
  ///
  /// The dialog and its TextEditingController are gone before the seal can
  /// throw, so a failure used to cost up to 1000 characters and reopen the
  /// editor seeded from the server. A farewell note is not text anybody types
  /// twice.
  String? _noteDraft;

  @override
  void initState() {
    super.initState();
    UnlinkState.current.addListener(_onState);
    _startTicking();
    unawaited(_loadNote());
  }

  @override
  void dispose() {
    UnlinkState.current.removeListener(_onState);
    _tick?.cancel();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    _noteLoad = _NoteLoad.pending;
    unawaited(_loadNote());
    setState(() {});
  }

  /// Server-relative and self-cancelling past the deadline, the rewrap
  /// pattern: a 1s tick that stops when there is nothing left to count.
  void _startTicking() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      final row = UnlinkState.current.value;
      if (row == null || row.due) t.cancel();
      if (mounted) setState(() {});
    });
  }

  /// Derive the couple key for this route, rather than hoping someone else did.
  ///
  /// Both halves of the note go through `CoupleKey.ready()`, which JOINS an
  /// in-flight derive and starts none — and nothing under features/unlink ever
  /// started one. A couple that reached the ceremony by push without opening
  /// chat or Closer in this process met a button that failed identically every
  /// time. `prime` is single-flight, so this joins session_provider's derive
  /// when there is one and runs it when there is not.
  Future<bool> _primeKey() => CoupleKey.prime(ref.read(sessionProvider));

  Future<void> _loadNote() async {
    final row = UnlinkState.current.value;
    if (row == null || !row.hasNote) {
      // Absent is a RESOLVED answer, and the cached text goes with it: the
      // author can clear their note, and a card still showing the retracted
      // words — or an editor prefilled with them — is the stale half of the
      // same conflation.
      if (mounted) {
        setState(() {
          _note = null;
          _noteLoad = _NoteLoad.absent;
        });
      }
      return;
    }
    await _primeKey();
    final text = await UnlinkRepository.openNote(row);
    if (!mounted) return;
    setState(() {
      _note = text;
      // openNote answers null for a note that IS stored and will not open on
      // this phone (it files the failure itself). That is not "no note", and
      // saying so is what put a blank editor over stored ciphertext.
      _noteLoad = text == null ? _NoteLoad.sealed : _NoteLoad.open;
    });
  }

  void _retryNote() {
    setState(() => _noteLoad = _NoteLoad.pending);
    unawaited(_loadNote());
  }

  /// True when the action landed. False is already reported and already on
  /// screen — callers use it only to decide what to do next.
  Future<bool> _run(
    Future<void> Function() action, {
    String? failure,
    VoidCallback? onRetry,
  }) async {
    setState(() => _busy = true);
    try {
      await action();
      await UnlinkState.load();
      return true;
    } catch (e, st) {
      // Filed, not just shown. Every verb of the ceremony comes through here,
      // and a re-link or a note that failed in the field left no trace
      // anywhere — during the one week where a control that does nothing costs
      // the most. openNote one file over has always reported; this did not.
      ErrorReporter.report(e, st, kind: 'unlink');
      if (mounted) _say(failure ?? "That didn't go through. Try again.", onRetry);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String message, [VoidCallback? onRetry]) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      action: onRetry == null
          ? null
          : SnackBarAction(label: 'Try again', onPressed: onRetry),
    ));
  }

  Future<void> _relink() async {
    await _run(() async {
      await UnlinkRepository.cancel();
      if (mounted && context.canPop()) context.pop();
    });
  }

  Future<void> _accept(String partnerName) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: const Text('Accept the unlink?',
            style: TextStyle(color: MilesColors.cream50),),
        // True for the only person who ever reads it. unlink_cancel deletes
        // `where initiated_by = auth.uid()` and unlink_accept only matches
        // state = 'cooling', which nothing writes back — so accepting is
        // one-way for the partner, and the Re-link button belongs to the other
        // side alone. The old second sentence promised both of them a change
        // of mind that only one of them has.
        content: Text(
          'A final day begins, and there is no taking this back from your '
          'side. Only $partnerName can still stop it — one tap on their '
          'Re-link button, any time before the day runs out.',
          style: const TextStyle(color: MilesColors.taupe),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not yet'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Accept',
                style: TextStyle(color: MilesColors.danger),),
          ),
        ],
      ),
    );
    if (sure ?? false) await _run(UnlinkRepository.accept);
  }

  /// Only a load still in flight closes the editor, and only until it lands.
  ///
  /// The hazard here was never "the box is blank" — it was a blank box under a
  /// button that says "Edit what you wrote", whose Save takes writeNote's empty
  /// branch and nulls note_cipher/note_nonce on the server. That is answered by
  /// [_sealedRewrite]: over an unreadable note the button says REPLACE, and an
  /// empty Save from that state does nothing at all.
  ///
  /// `sealed` deliberately stays editable. Barring it looks safe and is not: a
  /// key rotated by the rewrap ceremony mid-week — or any of the decrypt
  /// failures already in the field — makes openNote return null forever, and
  /// `prime` memoizes a COMPLETED TRUE, so Try again can never move it. That
  /// would leave the person being left with a greyed button for the whole seven
  /// days, which is a worse ending than the one this guard was protecting.
  bool get _canEditNote => _noteLoad != _NoteLoad.pending;

  /// Editing over ciphertext this phone cannot open: seed nothing, promise
  /// nothing, and refuse the destructive branch.
  bool get _sealedRewrite => _noteDraft == null && _noteLoad == _NoteLoad.sealed;

  Future<void> _writeNote(String coupleId) async {
    final sealedRewrite = _sealedRewrite;
    final existing = _noteDraft ?? _note ?? '';
    final controller = TextEditingController(text: existing);
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: Text(
          sealedRewrite ? 'Replace what you wrote' : 'Write something for them',
          style: const TextStyle(color: MilesColors.cream50),
        ),
        content: TextField(
          controller: controller,
          maxLines: 5,
          maxLength: 1000,
          autofocus: true,
          style: const TextStyle(color: MilesColors.cream50),
          decoration: InputDecoration(
            hintText: sealedRewrite
                ? 'This phone cannot open what is stored, so it starts empty. '
                    'Anything you write here replaces it.'
                : 'They will see this on their screen, beside the '
                    'button that brings them back.',
            hintStyle:
                const TextStyle(color: MilesColors.taupe, fontSize: 13),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (text == null) return;
    // The one branch that destroys server state, refused from the one state
    // that cannot have shown the author what they are destroying. Nothing was
    // typed and nothing was displayed, so this is a reflex Save on a box that
    // opened blank — not a decision to clear.
    if (sealedRewrite && text.trim().isEmpty) {
      _say('Nothing typed, so what they have is untouched.');
      return;
    }
    _noteDraft = text;
    // Clearing needs no key — writeNote's empty branch sends two nulls and
    // returns before it asks for one — but sealing does, and asking for it
    // here is the difference between a real reason and "That didn't go
    // through" on a control that will never work until the app is restarted.
    if (text.trim().isNotEmpty) {
      setState(() => _busy = true);
      final keyed = await _primeKey();
      if (!mounted) return;
      setState(() => _busy = false);
      if (!keyed) {
        ErrorReporter.report(
          const _NoteKeyUnavailable(),
          StackTrace.current,
          kind: 'unlink',
        );
        _say(
          "We can't unlock your side yet, so this isn't sealed. Your words "
          'are kept.',
          () => unawaited(_writeNote(coupleId)),
        );
        return;
      }
    }
    final ok = await _run(
      () => UnlinkRepository.writeNote(coupleId, text),
      failure: "That didn't save. Your words are kept.",
      onRetry: () => unawaited(_writeNote(coupleId)),
    );
    if (!ok) return;
    _noteDraft = null;
    _noteLoad = _NoteLoad.pending;
    await _loadNote();
  }

  String _countdown(UnlinkRow row) {
    final left = row.endsAt.difference(ServerClock.now());
    if (left.isNegative) return 'The window has closed';
    final days = left.inDays;
    final hours = left.inHours % 24;
    final minutes = left.inMinutes % 60;
    if (days > 0) {
      return '$days ${days == 1 ? 'day' : 'days'}, $hours h left';
    }
    if (left.inHours > 0) return '${left.inHours} h $minutes m left';
    return '$minutes m left';
  }

  /// The initiator's card, in both of the states worth a card.
  ///
  /// "They wrote nothing" and "they wrote something this phone cannot open"
  /// used to render identically — as nothing at all — so a failed decrypt in
  /// the one week that matters looked exactly like a partner who stayed
  /// silent. The ciphertext survives on the server until execute; what was
  /// missing was ever saying so.
  Widget _noteCard(String partnerName) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: MilesColors.surface1,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: MilesColors.gilt.withValues(alpha: 0.3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'From $partnerName',
              style: const TextStyle(
                color: MilesColors.gilt,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            if (_noteLoad == _NoteLoad.open)
              Text(
                _note!,
                style: const TextStyle(
                  color: MilesColors.cream50,
                  fontSize: 15,
                  height: 1.45,
                ),
              )
            else
              _sealedNote(
                'They left you something this phone cannot open yet.',
              ),
          ],
        ),
      );

  /// One shape for both sides of a note that will not open: what happened, and
  /// a retry that re-derives the key rather than only re-reading the row.
  Widget _sealedNote(String message) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: const TextStyle(
              color: MilesColors.taupe,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          TextButton(
            onPressed: _busy ? null : _retryNote,
            child: const Text(
              'Try again',
              style: TextStyle(color: MilesColors.gilt, fontSize: 13),
            ),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final row = UnlinkState.current.value;
    final session = ref.watch(sessionProvider);
    final uid = session.profile?.id;
    // A deep link with no ceremony, or one that just ended: nothing to show.
    if (row == null || uid == null) {
      return Scaffold(
        backgroundColor: MilesColors.night,
        appBar: AppBar(backgroundColor: Colors.transparent),
        body: const Center(
          child: Text('Nothing here anymore.',
              style: TextStyle(color: MilesColors.taupe),),
        ),
      );
    }

    final mine = row.iAmInitiator(uid);
    final quote = unlinkQuoteForDay();
    final partnerName = session.partner?.displayName ?? 'Your partner';

    return Scaffold(
      backgroundColor: MilesColors.night,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            children: [
              const SizedBox(height: 24),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => context.canPop()
                      ? context.pop()
                      : context.go('/app'),
                  child: const Text('Continue to app',
                      style: TextStyle(color: MilesColors.taupe),),
                ),
              ),
              // The ceremony's words scroll; its controls do not. Re-link is
              // the only cancel control in the whole client, and it used to
              // sit at the bottom of an unscrollable Column beneath an
              // unbounded note: roughly 350 characters of farewell — or a 2.0
              // font scale with no note at all — laid it out past the bottom
              // edge, where no pointer event can reach it and the week simply
              // ran out. Everything that can grow now lives inside this
              // viewport, and the controls are laid out before it gets any
              // space at all, so no length and no text scale can move them.
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) => SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: ConstrainedBox(
                      // Keeps the old Spacer-centred look while it fits, and
                      // becomes a scroll the moment it stops fitting. Minus
                      // the padding, or every screen scrolls by 32dp — and
                      // never below zero, which is what a viewport shorter
                      // than its own padding would ask for.
                      constraints: BoxConstraints(
                        minHeight:
                            box.maxHeight > 32 ? box.maxHeight - 32 : 0,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            mine
                                ? 'You asked to unlink'
                                : '$partnerName asked to unlink',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: MilesColors.taupe,
                              fontSize: 14,
                              letterSpacing: 0.4,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _countdown(row),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: MilesColors.gilt,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 40),
                          Text(
                            '“${quote.text}”',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: MilesColors.cream50,
                              fontSize: 22,
                              height: 1.5,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '— ${quote.author}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: MilesColors.taupe,
                              fontSize: 13,
                            ),
                          ),
                          if (mine &&
                              (_noteLoad == _NoteLoad.open ||
                                  _noteLoad == _NoteLoad.sealed)) ...[
                            const SizedBox(height: 40),
                            _noteCard(partnerName),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (row.due)
                Text(
                  mine
                      ? 'The week has passed. Opening the app again will '
                          'complete the unlink.'
                      : 'The window has closed.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: MilesColors.taupe),
                )
              else if (mine) ...[
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: MilesColors.ember,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    onPressed: _busy ? null : _relink,
                    child: const Text(
                      'Re-link',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: MilesColors.cream50,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'One tap, any day, and this never happened.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: MilesColors.taupe, fontSize: 12),
                ),
              ] else ...[
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                        color: MilesColors.gilt.withValues(alpha: 0.5),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(26),
                      ),
                    ),
                    onPressed: _busy || !_canEditNote
                        ? null
                        : () => _writeNote(row.coupleId),
                    child: Text(
                      // "Edit" promises the old text is in the box. Over
                      // ciphertext this phone cannot open it is not, so the
                      // verb changes rather than the promise being broken.
                      _sealedRewrite
                          ? 'Replace what you wrote'
                          : row.hasNote || _noteDraft != null
                              ? 'Edit what you wrote'
                              : 'Write something for them',
                      style: const TextStyle(
                        color: MilesColors.cream50,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
                // A disabled button with nothing beside it is the dead control
                // this screen already had once. Say which of the two reasons
                // it is, and give the sealed one its way out.
                // The button above is disabled only while the load is in
                // flight. The sealed case keeps its explanation and its retry,
                // but the control beside them stays live — see [_canEditNote].
                if (_noteLoad == _NoteLoad.pending) ...[
                  const SizedBox(height: 6),
                  const Text(
                    'Unlocking your side…',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: MilesColors.taupe, fontSize: 12),
                  ),
                ] else if (_sealedRewrite) ...[
                  const SizedBox(height: 6),
                  _sealedNote(
                    "This phone can't open what you wrote. Try again, or "
                    'replace it with something it can seal.',
                  ),
                ],
                const SizedBox(height: 12),
                if (!row.accepted)
                  TextButton(
                    onPressed: _busy ? null : () => _accept(partnerName),
                    child: const Text(
                      'Accept unlink',
                      style: TextStyle(color: MilesColors.danger),
                    ),
                  )
                else
                  const Text(
                    'Accepted — a final day is running.',
                    style: TextStyle(color: MilesColors.taupe, fontSize: 12),
                  ),
              ],
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => context.push('/app/settings/export'),
                child: const Text(
                  'Save your memories',
                  style: TextStyle(color: MilesColors.taupe, fontSize: 13),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
