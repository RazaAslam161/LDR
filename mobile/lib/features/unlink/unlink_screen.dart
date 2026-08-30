import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/couple_key.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/services/server_clock.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/countdown_digits.dart';
import 'package:miles/features/unlink/scene/ritual_scene.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';
import 'package:miles/features/unlink/scene/scene_sync.dart';
import 'package:miles/features/unlink/scene/unlink_end_overlay.dart';
import 'package:miles/features/unlink/unlink_completion.dart';
import 'package:miles/features/unlink/unlink_quotes.dart';
import 'package:miles/features/unlink/unlink_repository.dart';
import 'package:miles/features/unlink/unlink_state.dart';

/// The ritual's one screen, worn differently by its two people.
///
/// This is where the app goes while an unlinking is open. It is reached by the
/// router's own gate, not by a push behind a dismissible latch — the previous
/// version left both of them inside the app behind a banner, and the tap that
/// is meant to be the heaviest in the product read as nothing happening.
///
/// THE LETTER, for the person who started it: one quote, their partner's note
/// when there is one, the clock, and — after fifteen minutes — one large
/// Re-link button. Before those fifteen minutes the slot holds a live count,
/// never a greyed button: the wait is the ritual, and a disabled control is
/// how a ritual reads as a bug.
///
/// THE SPACE, for the person who did not: the same quote, a place to write the
/// one sealed note that appears on the other screen, a door to chat that stays
/// open the whole time, and — after fifteen minutes — a quiet way to agree.
/// It never names what the other person did. It does say what happens if
/// nothing changes, because being unlinked with no warning is worse than being
/// told softly.
///
/// LAST CALL, for both: five minutes and one button, once they have both
/// chosen it.
///
/// What is deliberately NOT here any more: "Continue to app". The ritual takes
/// the app away — that is the whole design. What replaces it is narrower and
/// safer: export, the account exit, and (for the partner only) chat.
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

  /// Set once the ceremony has ended by any door, so the teardown-and-leave
  /// runs exactly once however many notifiers fire.
  bool _leaving = false;

  /// A completion attempt is in flight, so the next tick does not stack a
  /// second one on top of it.
  bool _finishing = false;

  /// The tick a completion was last attempted on. Starts far enough behind that
  /// the first due tick attempts immediately; a refusal then retries on the same
  /// unhurried cadence as the refetch rather than hammering once a second.
  int _lastFinishAt = -15;
  String? _note;
  _NoteLoad _noteLoad = _NoteLoad.pending;

  /// What the author typed, held from Save until the write LANDS.
  ///
  /// The dialog and its TextEditingController are gone before the seal can
  /// throw, so a failure used to cost up to 1000 characters and reopen the
  /// editor seeded from the server. A farewell note is not text anybody types
  /// twice.
  String? _noteDraft;

  /// The ritual's own realtime ear. The router gate unmounted AppShell — and
  /// with it the app's only couple_unlink subscription — so until this
  /// existed, every beat after the start reached a phone standing INSIDE the
  /// ritual on the 15-second poll. The poll below stays as the floor.
  UnlinkSceneSync? _sync;

  @override
  void initState() {
    super.initState();
    UnlinkState.current.addListener(_onState);
    final coupleId = UnlinkState.current.value?.coupleId;
    final myUid = ref.read(currentProfileProvider)?.id;
    if (coupleId != null && myUid != null) {
      _sync = UnlinkSceneSync.start(coupleId: coupleId, myUid: myUid);
    }
    _startTicking();
    unawaited(_loadNote());
  }

  @override
  void dispose() {
    UnlinkState.current.removeListener(_onState);
    _sync?.dispose();
    _tick?.cancel();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    // The row is gone: re-linked from either side, or the couple dissolved.
    // Both end with this screen having nothing to say, and "Nothing here
    // anymore." is a dead end when the gate is what put you here — the shell
    // that used to notice is unmounted for the whole ritual.
    if (UnlinkState.current.value == null) {
      if (!_leaving) {
        _leaving = true;
        unawaited(_released());
      }
      return;
    }
    _noteLoad = _NoteLoad.pending;
    unawaited(_loadNote());
    setState(() {});
  }

  /// Whichever way it ended, this phone catches up and leaves.
  ///
  /// Guarded, because every exit routes through here: a local Re-link, the far
  /// phone's Re-link over realtime, the deadline, and the cron job. Running the
  /// teardown twice is survivable; navigating twice is not.
  Future<void> _released() async {
    final old = ref.read(currentCoupleProvider)?.id;
    final session = ref.read(sessionProvider.notifier);
    await session.loadProfile();
    if (!mounted) return;
    // A re-link leaves the couple standing; an execution does not, and this
    // phone may only be learning that now. Mirror of AppShell's
    // _onUnlinkChanged, which cannot run while the gate holds this screen up.
    final survives = ref.read(currentCoupleProvider) != null;
    if (!survives && old != null) {
      await ref.read(sessionProvider.notifier).endCouple(old);
    }
    // The farewell, above the router: setting a notifier is synchronous, so
    // the pinned teardown gains no await and the overlay plays OVER the
    // navigation. Re-link floods warm; dissolution lets the dusk fall.
    UnlinkEndOverlay.play.value =
        survives ? UnlinkEnding.relink : UnlinkEnding.ended;
    // '/app' either way. If the couple really is gone the funnel's needsCouple
    // gate turns this into '/couple' on the same redirect pass.
    if (mounted) context.go('/app');
  }

  /// The ritual's own heartbeat — and, while it is up, the app's.
  ///
  /// The router gate that brings anyone here UNMOUNTS AppShell, and AppShell
  /// is where the realtime subscription, the push drain and the deadline check
  /// all lived. Left as it was, this screen would have been the one place in
  /// the app where nothing was watching: a phone parked here at the deadline
  /// would show a stale row for ever, and a Re-link from the far side would
  /// never arrive. The takeover would have disabled its own completion.
  ///
  /// So: a 1s tick for the countdowns and the two gates opening, and a refetch
  /// every fifteenth of them. Fifteen seconds is deliberately unhurried — this
  /// is a fallback under realtime and the push, not a poll anything depends
  /// on, and the row is four timestamps.
  void _startTicking() {
    _tick?.cancel();
    var n = 0;
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      final at = ++n;
      final row = UnlinkState.current.value;
      if (row == null) {
        t.cancel();
        return;
      }
      if (row.due) {
        // Deliberately does NOT cancel before the RPC. This ticker IS the
        // retry, and cancelling first meant a refused execute — a transient
        // socket, or a clock argument the server wins — left nothing running:
        // the screen sat on a stale row for ever, past a deadline that had
        // already passed, with no way to notice the couple had been dissolved
        // from the other phone or by the job. It stops when the work is done.
        if (!_finishing && at - _lastFinishAt >= 15) {
          _lastFinishAt = at;
          _finishing = true;
          unawaited(
            _finish(row.coupleId).then((done) {
              if (done) t.cancel();
            }).whenComplete(() => _finishing = false),
          );
        }
        if (mounted) setState(() {});
        return;
      }
      if (at % 15 == 0) unawaited(UnlinkState.load());
      if (mounted) setState(() {});
    });
  }

  /// The deadline passed with this screen open. Either phone may finish it,
  /// and the per-minute job will too — whichever gets there first, the rest
  /// no-op.
  Future<bool> _finish(String coupleId) => completeUnlink(ref, coupleId);

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
      // Reset rather than reload: the row is gone, and a round trip to learn
      // that leaves the ritual on screen for the length of it. Clearing the
      // notifier releases the router gate on this phone immediately; the far
      // phone is released by realtime and by the unlink_relinked push.
      //
      // Navigation is deliberately NOT done here. The reset fires _onState,
      // which routes every ending — this one, the far phone's, the deadline,
      // the cron job — through _released(). One door out, so a local Re-link
      // cannot navigate twice or skip the profile reload the others need.
      UnlinkState.reset();
    });
  }

  Future<void> _accept(String partnerName) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: const Text('Are you sure?',
            style: TextStyle(color: MilesColors.cream50),),
        // Every sentence checked against the server. unlink_accept() clamps to
        // now() + 5 minutes; unlink_cancel() deletes `where initiated_by =
        // auth.uid()` in ANY state, so the other person keeps a live Re-link
        // right through the last call and this person never had one. Saying
        // "either of you can still stop it" here would be the false promise
        // the audit found in the version this replaces.
        content: Text(
          'This starts a five-minute goodbye, and there is no taking it back '
          'from your side. $partnerName will be told right away, and can '
          'still bring you both back until the five minutes run out.',
          style: const TextStyle(color: MilesColors.taupe),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not yet'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text("I'm sure",
                style: TextStyle(color: MilesColors.danger),),
          ),
        ],
      ),
    );
    if (sure ?? false) {
      final ok = await _run(UnlinkRepository.accept);
      // Their bolt should slide the moment this lands, not fifteen seconds
      // into a five-minute window.
      if (ok) _sync?.announceAgreed();
    }
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
    // The far phone gets its head start: the letter should emerge from their
    // door in ~100ms, not on the next poll. The write above already landed —
    // a lost broadcast costs nothing but the promptness.
    _sync?.announceLetter();
    _noteDraft = null;
    _noteLoad = _NoteLoad.pending;
    await _loadNote();
  }

  /// The deadline as a wall clock, in this phone's own timezone.
  ///
  /// "in 24 hours" is wrong the second the screen is left open, and this is
  /// the one line on the partner's side that has to stay true — it is the
  /// whole of what they are told. Local, not UTC and not the couple's primary
  /// timezone: the person reading it is deciding what to do with their
  /// evening.
  String _deadlineClock(UnlinkRow row) {
    final at = row.endsAt.toLocal();
    final h24 = at.hour;
    final h = h24 % 12 == 0 ? 12 : h24 % 12;
    final m = at.minute.toString().padLeft(2, '0');
    final ampm = h24 < 12 ? 'am' : 'pm';
    final sameDay = at.day == DateTime.now().day;
    return '$h:$m$ampm${sameDay ? '' : ' tomorrow'}';
  }

  /// One measure for every line of prose on this screen.
  ///
  /// The screen felt overcrowded largely because nothing constrained the line
  /// length: at 360dp minus padding, sentences ran the full 312 and the eye
  /// had no column to follow. 300 keeps a comfortable measure and, being a
  /// max, it simply stops applying on a narrow phone or a large text scale
  /// rather than clipping anything.
  Widget _measure(Widget child) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: child,
      );

  /// The screen's one voice for anything that is not a heading or a control.
  ///
  /// There were four different sizes and three different colours doing this
  /// job. One shape means the eye can tell instantly what is an instruction
  /// and what is the app talking quietly beside it.
  Widget _quiet(String text) => _measure(
        Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: MilesColors.taupe,
            fontSize: 12,
            height: 1.55,
          ),
        ),
      );

  /// A deadline, ticking, on the server's clock.
  Widget _clock(DateTime until) => Center(
        child: CountdownDigits(
          until: until,
          clock: ServerClock.now,
          style: const TextStyle(fontSize: 26),
        ),
      );

  /// A closed gate: what is being waited for, and how long is left.
  ///
  /// Both sides get this, and that symmetry is the point. Only the initiator
  /// had a countdown before; the partner was handed a sentence with no clock
  /// and no way to tell two minutes from twenty.
  Widget _wait(String label, DateTime until) => Column(
        children: [
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: MilesColors.faint,
              fontSize: 12,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 8),
          _clock(until),
        ],
      );

  /// The way back. One shape, used by the held state and the last call, so the
  /// button cannot drift between the two moments it matters most.
  Widget _relinkButton() => SizedBox(
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
      );

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
    // The NARROWEST providers that answer the question, per providers.dart —
    // and the reason this screen can be rendered in a test at all. Watching
    // the whole SessionState pulled SessionNotifier (and with it Supabase and
    // a live socket) into anything that tried to mount the ritual, which is
    // why the layout CRITICAL was source-read four times and never rendered.
    // _primeKey still reads the bundle: CoupleKey.prime needs all of it.
    final uid = ref.watch(currentProfileProvider)?.id;
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
    // This ceremony's quote, not this day's: a one-day window started in the
    // evening would otherwise change its own words at midnight, under both of
    // them, halfway through.
    final quote = unlinkQuoteForCeremony(row.startedAt);
    final partnerName =
        ref.watch(partnerProfileProvider)?.displayName ?? 'Your partner';

    return Scaffold(
      backgroundColor: MilesColors.night,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              // The words scroll; the controls never do. Re-link is the only
              // caller of unlink_cancel in the client, and it once sat at the
              // bottom of an unscrollable Column under an unbounded note —
              // 350 characters of farewell, or a 2.0 text scale with no note
              // at all, laid it out past the bottom edge where no pointer can
              // reach it. Everything that can GROW lives inside this viewport;
              // everything that must be TAPPED is laid out before the viewport
              // is given any space at all.
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) => SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 28),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight:
                            box.maxHeight > 56 ? box.maxHeight - 56 : 0,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _measure(
                            Text(
                              // The initiator is told plainly, because they
                              // did it. The partner is NOT told what happened
                              // — naming it turns a fight into a verdict, and
                              // protecting the other one's pride is half of
                              // why this window exists. The consequence is
                              // still stated in full, lower down.
                              mine
                                  ? 'You closed the door.'
                                  : '$partnerName needs a little space '
                                      'right now.',
                              textAlign: TextAlign.center,
                              style: MilesType.fraunces(
                                fontSize: 26,
                                height: 1.3,
                              ).copyWith(color: MilesColors.cream50),
                            ),
                          ),
                          const SizedBox(height: 10),
                          _measure(
                            Text(
                              mine
                                  ? "It isn't locked."
                                  : "They haven't gone anywhere.",
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: MilesColors.taupe,
                                fontSize: 15,
                                height: 1.45,
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          // The Doorstep: the street, the door, the lamp, the
                          // bird who says the quote. When the stage fits, the
                          // scene IS the quote block; when it does not —
                          // animations off, or a text scale that needs the
                          // room — the calm layout below stands alone, same
                          // words, same rules.
                          if (RitualScene.fits(context))
                            RitualScene(
                              row: row,
                              role: mine
                                  ? SceneRole.outside
                                  : SceneRole.inside,
                              variant: puppetVariantOf(
                                ref.watch(currentProfileProvider)?.gender,
                              ),
                              quoteText: quote.text,
                              quoteAuthor: quote.author,
                              // The doorstep envelope unfolds into the same
                              // card the calm layout shows — one card, one
                              // set of note states, two stagings.
                              letterCard: mine &&
                                      (_noteLoad == _NoteLoad.open ||
                                          _noteLoad == _NoteLoad.sealed)
                                  ? _noteCard(partnerName)
                                  : null,
                            )
                          else ...[
                            const SizedBox(height: 8),
                            // One hairline instead of a second heading: ours
                            // above, somebody else's words below.
                            Container(
                              width: 40,
                              height: 1,
                              color: MilesColors.hairline,
                            ),
                            const SizedBox(height: 32),
                            // Deliberately SMALLER than the headline, so the
                            // borrowed quote never outranks the app's own
                            // sentence.
                            _measure(
                              Text(
                                '“${quote.text}”',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: MilesColors.cream50,
                                  fontSize: 18,
                                  height: 1.6,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              quote.author,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: MilesColors.faint,
                                fontSize: 12,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ],
                          if (!RitualScene.fits(context) &&
                              mine &&
                              (_noteLoad == _NoteLoad.open ||
                                  _noteLoad == _NoteLoad.sealed)) ...[
                            const SizedBox(height: 32),
                            _noteCard(partnerName),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (row.due)
                _quiet('The window has closed. This is finishing now.')
              else if (row.lastCall) ...[
                if (mine) ...[
                  _relinkButton(),
                  const SizedBox(height: 12),
                  _quiet(
                    '$partnerName is ready to let go. This is the last '
                    'moment either of you can stop it.',
                  ),
                ] else
                  _quiet(
                    'You both chose this. $partnerName can still bring you '
                    'back until it closes.',
                  ),
                const SizedBox(height: 16),
                _clock(row.endsAt),
              ] else if (mine) ...[
                if (row.relinkOpen) ...[
                  _relinkButton(),
                  const SizedBox(height: 12),
                  _quiet('One tap, and none of this happened.'),
                ] else
                  // Never a greyed button. The wait IS the ritual, and a
                  // disabled control with no explanation is how this whole
                  // feature read as broken the first time.
                  _wait('The way back opens in', row.relinkOpensAt),
                const SizedBox(height: 18),
                _quiet('Ends ${_deadlineClock(row)}'),
              ] else ...[
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                        color: MilesColors.gilt.withValues(alpha: 0.45),
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
                if (_noteLoad == _NoteLoad.pending) ...[
                  const SizedBox(height: 8),
                  _quiet('Unlocking your side…'),
                ] else if (_sealedRewrite) ...[
                  const SizedBox(height: 8),
                  _sealedNote(
                    "This phone can't open what you wrote. Try again, or "
                    'replace it with something it can seal.',
                  ),
                ],
                const SizedBox(height: 18),
                // Soft in tone, honest in substance. This screen never says
                // what the other person did, but it cannot let somebody be
                // unlinked with no warning — that is the app lying by
                // omission at the highest-stakes moment it has. An absolute
                // wall-clock time, because "in 24 hours" stops being true the
                // moment the screen is left open.
                _quiet(
                  'If nothing changes by ${_deadlineClock(row)}, Miles will '
                  'close your shared space — and keep it safe for 30 days.',
                ),
                const SizedBox(height: 14),
                if (row.partnerGateOpen)
                  TextButton(
                    onPressed: _busy ? null : () => _accept(partnerName),
                    child: const Text(
                      'I need space too',
                      style: TextStyle(
                        color: MilesColors.danger,
                        fontSize: 13,
                      ),
                    ),
                  )
                else
                  // The same courtesy the other side gets while ITS control is
                  // closed. This branch was one line of prose with no clock,
                  // so the person being left could not tell two minutes from
                  // twenty — waiting with no visible end is precisely what
                  // this screen exists to spare them.
                  _wait('You can decide in', row.partnerGateOpensAt),
              ],
              const SizedBox(height: 18),
              // Always, for both, at every stage. A ritual that holds your
              // photographs is a threat rather than a pause, and the account
              // exit is never gated on the ceremony (assertion #4 of
              // 20260829120000, and Play policy besides). Wrap, not Row: at a
              // 2.0 text scale a Row of these two overflows, and an
              // overflowing Row in a release build silently lays its last
              // child past the edge — the exact bug that made Begin
              // untappable on the sheet before this screen.
              Wrap(
                alignment: WrapAlignment.center,
                children: [
                  TextButton(
                    onPressed: () => context.push('/app/settings/export'),
                    child: const Text(
                      'Save our memories',
                      style:
                          TextStyle(color: MilesColors.taupe, fontSize: 13),
                    ),
                  ),
                  TextButton(
                    onPressed: () => context.push('/app/settings/account'),
                    child: const Text(
                      'Account',
                      style:
                          TextStyle(color: MilesColors.faint, fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
