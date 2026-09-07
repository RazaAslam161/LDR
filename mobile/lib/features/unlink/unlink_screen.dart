import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/couple_key.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/services/server_clock.dart';
import 'package:miles/core/services/sound/cue.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/countdown_digits.dart';
import 'package:miles/features/unlink/scene/doorstep_clock.dart';
import 'package:miles/features/unlink/scene/doorstep_scene.dart';
import 'package:miles/features/unlink/scene/film_library.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';
import 'package:miles/features/unlink/scene/scene_sync.dart';
import 'package:miles/features/unlink/scene/unlink_end_overlay.dart';
import 'package:miles/features/unlink/unlink_completion.dart';
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
    // SEEDED HERE, not only in _onState. _lastRow is what the ending reads to
    // decide WHOSE film plays, and _onState only ever runs on a CHANGE — so a
    // ceremony that is re-linked before any update lands (the row arrives with
    // the screen, the gate is already open, the key is tapped) reached the
    // teardown with a null row, no gender, and therefore no film at all: the
    // 900ms light alone, which looks exactly like the film being cut off.
    _lastRow = UnlinkState.current.value;
    final coupleId = UnlinkState.current.value?.coupleId;
    final myUid = ref.read(currentProfileProvider)?.id;
    if (coupleId != null && myUid != null) {
      _sync = UnlinkSceneSync.start(coupleId: coupleId, myUid: myUid);
      // The phone: their knock refetches; so does mounting.
      UnlinkSceneSync.onMessage = () => unawaited(_fetchMessages());
      unawaited(_fetchMessages());
    }
    _startTicking();
    unawaited(_loadNote());
  }

  @override
  void dispose() {
    UnlinkState.current.removeListener(_onState);
    UnlinkSceneSync.onMessage = null;
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
    _lastRow = UnlinkState.current.value;
    _noteLoad = _NoteLoad.pending;
    unawaited(_loadNote());
    setState(() {});
  }

  /// The last non-null row seen, kept because the ending needs facts from a
  /// row whose DELETION is what triggers the ending — by teardown time
  /// UnlinkState.current is already null on the relink path.
  UnlinkRow? _lastRow;

  /// Whichever way it ended, this phone catches up and leaves.
  ///
  /// Guarded, because every exit routes through here: a local Re-link, the far
  /// phone's Re-link over realtime, the deadline, and the cron job. Running the
  /// teardown twice is survivable; navigating twice is not.
  Future<void> _released() async {
    // THE ENDING MUST OUTLIVE THIS SCREEN.
    //
    // The row's deletion is what triggers this, and it is ALSO what makes the
    // router's gate stop allowing '/unlink' — so this widget is unmounted
    // somewhere inside the `loadProfile()` below. There used to be an
    // `if (!mounted) return;` immediately after that await, which meant the
    // relink path reached it, returned, and never set the notifiers: the
    // reunion film did not play, and neither did the light. Reported from the
    // handset as "even after re-link, reunion video doesn't even play".
    //
    // Everything this needs is now read through the CONTAINER, which outlives
    // the widget, and every fact the film choice depends on is captured
    // BEFORE the await. Only the navigation is still guarded by `mounted`,
    // because only the navigation actually needs a live element.
    final container = ProviderScope.containerOf(context, listen: false);
    final old = container.read(currentCoupleProvider)?.id;
    final session = container.read(sessionProvider.notifier);
    final initiator = _lastRow?.initiatedBy;
    final me = container.read(currentProfileProvider);
    final partner = container.read(partnerProfileProvider);
    final initiatorGender = initiator == null
        ? null
        : (initiator == me?.id ? me?.gender : partner?.gender);

    await session.loadProfile();
    // A re-link leaves the couple standing; an execution does not, and this
    // phone may only be learning that now. Mirror of AppShell's
    // _onUnlinkChanged, which cannot run while the gate holds this screen up.
    // The flag first, because the provider read below races the very teardown
    // that called this: on the execute path completeUnlink sets it, then
    // reset() re-enters here synchronously — before its own endCouple and
    // loadProfile have run — so currentCoupleProvider still answers non-null
    // and this phone played the REUNION ending over a couple it had just
    // destroyed. One-shot, cleared here so a later ceremony starts clean.
    final endedHere = UnlinkState.endedHere;
    UnlinkState.endedHere = false;
    final survives =
        !endedHere && container.read(currentCoupleProvider) != null;
    if (!survives && old != null) {
      await container.read(sessionProvider.notifier).endCouple(old);
    }
    // The farewell, above the router: setting a notifier is synchronous, so
    // the pinned teardown gains no await and the overlay plays OVER the
    // navigation. Re-link floods warm; dissolution lets the dusk fall.
    // The film choice rides the same synchronous write: whoever was OUTSIDE
    // is the one who walks back in or away, so the initiator's gender picks
    // the clip — identically on both phones. Null (neutral/unknown) keeps
    // the light-only ending.
    UnlinkEndOverlay.initiatorMale.value = switch (initiatorGender) {
      'male' => true,
      'female' => false,
      _ => null,
    };
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
      // The floor under the phone's knock, same as the row's.
      if (at % 15 == 0) unawaited(_fetchMessages());
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

  /// Returns whether the agreement actually landed — the tear animation is
  /// latched on the way in and has to be undone when it did not.
  Future<bool> _accept(String partnerName) async {
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
      return ok;
    }
    return false;
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

  /// The words, shared with the calm layout so the story cannot fork.
  ///
  /// Grounded in the scene: the initiator IS on the porch in the picture
  /// behind these words, so "stepped outside" is a description, not a
  /// verdict. The partner is still never told what happened — they are told
  /// where their person is.
  String _headline(bool mine, String partnerName) => mine
      ? 'You stepped outside.'
      : '$partnerName stepped out to the porch.';

  /// The corner plate's inner width, and the whole box the scene must keep
  /// its conversation out of.
  ///
  /// Sized DOWN from 138 after the handset showed the plate covering the
  /// cat's line mid-word: it is a glance, not a panel. The scene is told the
  /// rectangle rather than left to guess, because the plate paints after the
  /// stage and would otherwise always win.
  static const _plateInnerWidth = 92.0;
  static const _plateWidth = _plateInnerWidth + 16;

  /// "in 23h" / "in 45m" — the whole ceremony's remaining span, short enough
  /// to sit on one line beside a 34pt clock.
  String _deadlineShort(UnlinkRow row) {
    final left = row.endsAt.difference(ServerClock.now());
    if (left.isNegative) return 'now';
    if (left.inHours >= 1) return 'in ${left.inHours}h';
    return 'in ${left.inMinutes}m';
  }

  /// How long until MY gate opens. Zero once it has.
  Duration _gateLeft(UnlinkRow row) {
    final left = _myGate(row).difference(ServerClock.now());
    return left.isNegative ? Duration.zero : left;
  }

  static String _mmss(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:'
      '${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  /// THE FIFTEEN MINUTES, IN FIGURES, AND WHAT THEY BUY.
  ///
  /// This corner used to carry an analog dial and the sentence "Ends 08:47" —
  /// the TWENTY-FOUR HOUR deadline. So the one number on screen answered a
  /// question nobody was asking, the dial's minute hand crept a quarter turn
  /// across the whole wait, and nothing anywhere said that a choice was
  /// coming at all. Reported three separate times as "there is no timer", and
  /// once as "how would user know that there is still a chance to re-link".
  ///
  /// I had a design law that a countdown "manufactures urgency". The owner
  /// has overruled it three times; the law loses. What survives of it is the
  /// part that was actually right: the figures count the GATE, not the day,
  /// and they are gone the moment the gate opens — replaced by what you can
  /// now do. A number that keeps running after it means anything is nagging.
  List<Widget> _gateReadout(UnlinkRow row, {required bool mine}) {
    if (row.due) {
      return const [
        Text(
          'This is finishing now.',
          style: TextStyle(color: MilesColors.taupe, fontSize: 12),
        ),
      ];
    }
    final left = _gateLeft(row);
    final open = left == Duration.zero;
    return [
      if (!open) ...[
        Text(
          _mmss(left),
          style: MilesType.inter(
            fontSize: 17,
            color: MilesColors.gilt,
            decoration: TextDecoration.none,
          ).copyWith(
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
            height: 1.05,
          ),
        ),
        Text(
          // One line at this width, both roles. "until you can answer this"
          // wrapped to two and pushed the plate down over the cat.
          mine ? 'till the door opens' : 'till you can answer',
          textAlign: TextAlign.right,
          style: const TextStyle(color: MilesColors.taupe, fontSize: 9.5),
        ),
      ] else
        SizedBox(
          width: _plateInnerWidth,
          child: Text(
            mine ? 'The key is on the door.' : 'You can answer now.',
            textAlign: TextAlign.right,
            style: const TextStyle(color: MilesColors.gilt, fontSize: 11.5),
          ),
        ),
      Text(
        // Relative, not absolute, on the STAGE only: "Ends 11:33am tomorrow"
        // wraps at this width and the calm layout already states the clock
        // time in full. The day is context here, not an appointment.
        'Ends ${_deadlineShort(row)}',
        style: const TextStyle(color: MilesColors.faint, fontSize: 9.5),
      ),
      if (!mine)
        const Text(
          'kept safe 30 days',
          style: TextStyle(color: MilesColors.faint, fontSize: 9.5),
        ),
    ];
  }

  /// The clock's two spans: what is left, out of what whole.
  ///
  /// THE WINDOW MUST BE THE ONE THE USER IS LIVING IN. This counted the
  /// 24-hour cooling span from the first second, so through the fifteen
  /// minutes that actually matter — the conversation, the wait for the gate —
  /// the hand swept 3.75 degrees and the arc drained 1%. On a real handset
  /// that is indistinguishable from a stopped clock, and it was reported as
  /// one. Before the gate the clock counts THE GATE: the same timestamp the
  /// bird's last line is pinned to, so the dial, the conversation and the
  /// button all finish together. After it, the day. In last call, its own
  /// five minutes.
  DateTime _windowEnd(UnlinkRow row) {
    if (row.lastCall) return row.endsAt;
    final gate = _myGate(row);
    return gate.isAfter(ServerClock.now()) ? gate : row.coolingEndsAt;
  }

  DateTime _windowStart(UnlinkRow row) {
    if (row.lastCall) return row.acceptedAt ?? row.startedAt;
    return row.startedAt;
  }

  /// Whichever fifteen-minute gate is mine to wait out.
  DateTime _myGate(UnlinkRow row) =>
      row.iAmInitiator(ref.read(currentProfileProvider)?.id ?? '')
          ? row.relinkOpensAt
          : row.partnerGateOpensAt;

  Duration _remainingWindow(UnlinkRow row) {
    final left = _windowEnd(row).difference(ServerClock.now());
    return left.isNegative ? Duration.zero : left;
  }

  Duration _totalWindow(UnlinkRow row) {
    final whole = _windowEnd(row).difference(_windowStart(row));
    return whole.isNegative ? Duration.zero : whole;
  }

  String _subline(bool mine) =>
      mine ? "The door isn't locked." : "They're right outside.";

  /// THE STAGE LAYOUT. Design law: the scene is the sentence.
  ///
  ///  * NO headline — the film already says it. Words belong to the calm
  ///    layout, where there is no picture to say them.
  ///  * NO ticking countdown while waiting. A counter manufactures urgency;
  ///    this ritual exists to remove it. One quiet ABSOLUTE line, top-right:
  ///    when this ends. The 15-minute gate is announced by the companion's
  ///    closing line and the button rising — script, gate and button all
  ///    read the same timestamp, so they cannot disagree. The ticking clock
  ///    keeps exactly one honest home: the five-minute last call.
  ///  * ONE voice on the stage — the companion's. The literary quote stays
  ///    in the calm layout.
  ///  * ONE primary action, and only while it exists. No greyed buttons, no
  ///    waiting rows: absence of a button IS the "not yet".
  ///  * Exits stay at every stage (law), whisper-quiet at the very bottom.
  Widget _stageLayout(
    BuildContext context,
    UnlinkRow row, {
    required bool mine,
    required String partnerName,
  }) {
    final h = MediaQuery.sizeOf(context).height;
    final noteReady =
        _noteLoad == _NoteLoad.open || _noteLoad == _NoteLoad.sealed;
    return Scaffold(
      backgroundColor: MilesColors.night,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: DoorstepScene(
              row: row,
              role: mine ? SceneRole.outside : SceneRole.inside,
              variant: puppetVariantOf(
                ref.watch(currentProfileProvider)?.gender,
              ),
              talkBottomInset: h * 0.20,
              // The clock plate's own corner, handed over so the conversation
              // keeps out from under it. Height is the plate at its tallest
              // (clock + figures + three small lines) plus the safe area it
              // sits inside; over-reserving costs a narrower bubble, while
              // under-reserving costs a sentence nobody can read.
              talkAvoid: Rect.fromLTWH(
                MediaQuery.sizeOf(context).width - _plateWidth - 14,
                0,
                _plateWidth + 14,
                MediaQuery.paddingOf(context).top + 118,
              ),
              // The owner's symbols: outside, the key appears when the way
              // back opens — using it is coming home. Inside, the framed
              // photo arms when the partner's gate opens — tearing it is
              // the agreement, behind one plain question.
              actionTorn: _torn,
              phoneLine: _latestFromThem,
              phoneGlow: _phoneGlowing,
              actionArmed: mine
                  ? (row.relinkOpen || row.lastCall) && !row.due
                  : row.partnerGateOpen && !row.lastCall && !row.due,
              onAction: _busy
                  ? null
                  : mine
                      ? _relink
                      : () => _confirmTear(context, row),
            ),
          ),
          // Time, as an object in the scene — the owner's call: a small
          // clock in the corner, not a readout on the chrome. Its hands and
          // depleting arc are painted from the row's own timestamps; in the
          // last call it wakes (second hand, ember arc). The caption beneath
          // carries the absolute end — and for the partner, the one sentence
          // the app may not omit.
          Positioned(
            top: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: 8, right: 14),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // scrim over the stage — bare figures sat straight on the
                    // porch lamp and the lit window behind it, and neither the
                    // count nor the sentence could be read at all. Time has to
                    // survive whatever art is under it.
                    // 0.72 is the same floor the speech bubbles use; 0.55 was
                    // readable over the night sky and not over the lit doorway.
                    color: MilesColors.nightDeep.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                  child: SizedBox(
                  width: _plateInnerWidth,
                  child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DoorstepClock(
                      remaining: _remainingWindow(row),
                      total: _totalWindow(row),
                      lastCall: row.lastCall && !row.due,
                      // Half the size it was. The object is the owner's design
                      // and stays; it just stops being the subject.
                      dimension: row.lastCall ? 40 : 34,
                      body: FilmLibrary.still(
                        mine
                            ? FilmLibrary.clockPorch
                            : FilmLibrary.clockRoom,
                      ),
                      dial: mine ? DialSpec.porch : DialSpec.room,
                    ),
                    const SizedBox(height: 2),
                    ..._gateReadout(row, mine: mine),
                  ],
                  ),
                  ),
                  ),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: h * 0.42),
                  child: SingleChildScrollView(
                    reverse: true,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // The farewell note, only when there is one to show.
                        if (mine && noteReady) ...[
                          _noteCard(partnerName),
                          const SizedBox(height: 12),
                        ],
                        ..._stageActions(row,
                            mine: mine, partnerName: partnerName,),
                        const SizedBox(height: 6),
                        // The exits: present at every stage, whispering.
                        Wrap(
                          alignment: WrapAlignment.center,
                          children: [
                            TextButton(
                              onPressed: () =>
                                  context.push('/app/settings/export'),
                              child: Text(
                                'Save our memories',
                                style: TextStyle(
                                  color: MilesColors.taupe
                                      .withValues(alpha: 0.75),
                                  fontSize: 11.5,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () =>
                                  context.push('/app/settings/account'),
                              child: Text(
                                'Account',
                                style: TextStyle(
                                  color: MilesColors.faint
                                      .withValues(alpha: 0.8),
                                  fontSize: 11.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The stage's actions: at most ONE pill, plus the partner's quiet second
  /// choice. A closed gate shows NOTHING — the companion's script is the
  /// "not yet", and an absent button cannot be mistaken for a broken one.
  List<Widget> _stageActions(
    UnlinkRow row, {
    required bool mine,
    required String partnerName,
  }) {
    if (row.due) return const [];
    if (row.lastCall) {
      // The one urgent moment keeps its reason ON the stage: the key with
      // five minutes on the clock and no explanation reads as a trap.
      return [
        if (mine)
          _quiet(
            '$partnerName is ready to let go. The key by the door is the '
            'last moment either of you can stop it.',
          )
        else
          _quiet(
            'You both chose this. $partnerName can still bring you '
            'back until it closes.',
          ),
      ];
    }
    // ONE pill for both of them, and it is the PHONE — the live channel the
    // owner asked for. The farewell letter lives inside the sheet, one quiet
    // link deep, partner-side only (the note is the voice of the person
    // being left; the RPC enforces it).
    return [
      SizedBox(
        width: double.infinity,
        height: 52,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            // scrim over the stage — the pill floats on the film's held
            // frame, and the 0.55 night fill is what keeps its label legible
            // over any lighting the clip ends on.
            backgroundColor:
                MilesColors.night.withValues(alpha: 0.55),
            side: BorderSide(
              color: MilesColors.gilt.withValues(alpha: 0.45),
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(26),
            ),
          ),
          onPressed: _busy ? null : () => _openPhone(row),
          child: const Text(
            'Write to them',
            style: TextStyle(
              color: MilesColors.cream50,
              fontSize: 15,
            ),
          ),
        ),
      ),
    ];
  }

  /// One plain question before the photo tears. The words carry the weight;
  /// the danger colour goes to the act, not to decoration.
  Future<void> _confirmTear(BuildContext context, UnlinkRow row) async {
    final partnerName =
        ref.read(partnerProfileProvider)?.displayName ?? 'Your partner';
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: const Text(
          'End it from your side too?',
          style: TextStyle(color: MilesColors.cream50, fontSize: 18),
        ),
        content: const Text(
          'This starts a five-minute goodbye, and there is no taking it '
          'back after that.',
          style: TextStyle(color: MilesColors.taupe, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Not now',
              style: TextStyle(color: MilesColors.cream100),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'I need space too',
              style: TextStyle(color: MilesColors.danger),
            ),
          ),
        ],
      ),
    );
    if (sure ?? false) {
      // The tear is SEEN: the halves for one settled breath, then the accept
      // (whose realtime + the parting film carry the rest).
      if (mounted) setState(() => _torn = true);
      await Future<void>.delayed(MilesMotion.reveal);
      // Put back unless the agreement actually landed. _torn had one writer and
      // no reset, so declining the SECOND confirmation ("Not yet") — or an
      // accept that failed — left the photograph visibly torn in half for the
      // rest of the ceremony, up to 24 hours, under the hint "Tear it, and you
      // agree": the screen showed an irreversible agreement the user had just
      // refused to make.
      final agreed = await _accept(partnerName);
      if (!agreed && mounted) setState(() => _torn = false);
    }
  }

  bool _torn = false;

  UnlinkMessages? _messages;

  /// When the newest message from THEM was written, and when this phone
  /// first saw it. A text used to arrive by silently swapping the words in a
  /// bubble — no sound, no buzz, nothing moving. If you were not staring at
  /// that exact corner of the scene, you never knew they had written.
  DateTime? _theirLatest;
  DateTime? _theirLatestSeenAt;

  /// The scene's phone stays lit for a while after a text lands, so it is
  /// still findable when you look up a few seconds later.
  bool get _phoneGlowing =>
      _theirLatestSeenAt != null &&
      ServerClock.now().difference(_theirLatestSeenAt!).inSeconds < 25;

  Future<void> _fetchMessages() async {
    final row = UnlinkState.current.value;
    if (row == null) return;
    try {
      final msgs = await UnlinkRepository.fetchMessages(row);
      if (!mounted) return;
      final uid = ref.read(currentProfileProvider)?.id;
      final theirs = [for (final m in msgs.items) if (m.sender != uid) m];
      final newest = theirs.isEmpty ? null : theirs.last.at;
      // Compared BEFORE the assignment below, or every 15-second poll would
      // re-announce the same message for as long as the ceremony lasts.
      final arrived = newest != null && newest != _theirLatest;
      // Never on the first load: opening the screen to a chime for something
      // written an hour ago is a false alarm this ceremony cannot afford.
      final firstLoad = _messages == null;
      setState(() {
        _messages = msgs;
        if (arrived) {
          _theirLatest = newest;
          _theirLatestSeenAt = ServerClock.now();
        }
      });
      if (arrived && !firstLoad) {
        MilesSound.cue(Cue.receive);
        unawaited(HapticFeedback.lightImpact());
      }
    } catch (e) {
      debugPrint('unlink messages fetch failed: $e');
    }
  }

  /// The other phone's newest words, for the scene bubble.
  String? get _latestFromThem {
    final uid = ref.read(currentProfileProvider)?.id;
    final items = _messages?.items;
    if (items == null) return null;
    for (final m in items.reversed) {
      if (m.sender != uid) {
        return m.failedToOpen ? "…a message this phone can't open yet." : m.text;
      }
    }
    return null;
  }

  Future<void> _openPhone(UnlinkRow row) async {
    final partnerName =
        ref.read(partnerProfileProvider)?.displayName ?? 'Your partner';
    final composer = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: MilesColors.surface1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(ctx).bottom,
          ),
          child: SizedBox(
            height: MediaQuery.sizeOf(ctx).height * 0.62,
            child: Column(
              children: [
                // THE WAY OUT, VISIBLE. This opened over the scene with no
                // handle and no close — dismissible only by tapping a scrim
                // mostly hidden behind the keyboard — and it read as a trap:
                // "if it opens it stays". The ceremony's own law is that
                // every exit stays on screen; a sheet is not exempt from it.
                const SizedBox(height: 8),
                Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: MilesColors.taupe.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Row(
                  children: [
                    const SizedBox(width: 4),
                    Semantics(
                      button: true,
                      label: 'Close',
                      child: IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close_rounded,
                            size: 20, color: MilesColors.taupe,),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          Text(
                            partnerName,
                            style: MilesType.fraunces(fontSize: 17)
                                .copyWith(color: MilesColors.cream50),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Only the two of you can read this.',
                            style: TextStyle(
                                color: MilesColors.faint, fontSize: 11.5,),
                          ),
                        ],
                      ),
                    ),
                    // Balances the close button so the name stays centred.
                    const SizedBox(width: 48),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _messages == null || _messages!.items.isEmpty
                      ? const Center(
                          child: Text(
                            'Nothing yet. Say something small.',
                            style: TextStyle(
                              color: MilesColors.taupe,
                              fontSize: 13,
                            ),
                          ),
                        )
                      : ListView(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 18),
                          children: [
                            for (final m in _messages!.items)
                              Align(
                                alignment: m.sender ==
                                        ref
                                            .read(currentProfileProvider)
                                            ?.id
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: Container(
                                  margin:
                                      const EdgeInsets.only(bottom: 6),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  constraints: const BoxConstraints(
                                    maxWidth: 260,
                                  ),
                                  decoration: BoxDecoration(
                                    color: MilesColors.surface2,
                                    borderRadius:
                                        BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    m.failedToOpen
                                        ? "…this phone can't open this "
                                            'one yet.'
                                        : m.text!,
                                    style: TextStyle(
                                      color: m.failedToOpen
                                          ? MilesColors.faint
                                          : MilesColors.cream100,
                                      fontSize: 14,
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
                if (!mineOf(row)) ...[
                  TextButton(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _writeNote(row.coupleId);
                    },
                    child: const Text(
                      'Leave them a letter instead',
                      style: TextStyle(
                        color: MilesColors.gilt,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: composer,
                          maxLength: 500,
                          maxLines: 3,
                          minLines: 1,
                          style: const TextStyle(
                            color: MilesColors.cream100,
                            fontSize: 14,
                          ),
                          decoration: const InputDecoration(
                            counterText: '',
                            hintText: 'Say something…',
                            hintStyle: TextStyle(color: MilesColors.faint),
                            filled: true,
                            fillColor: MilesColors.surface2,
                            border: OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.all(Radius.circular(22)),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: () async {
                          final text = composer.text;
                          if (text.trim().isEmpty) return;
                          composer.clear();
                          // The sound belongs to the gesture, not the ack.
                          MilesSound.cue(Cue.send);
                          try {
                            await UnlinkRepository.sendMessage(
                              row.coupleId,
                              text,
                            );
                            _sync?.announceMessage();
                            await _fetchMessages();
                            setSheet(() {});
                          } catch (e) {
                            // A send that fails used to clear the box and say
                            // nothing: the words were gone and the sender
                            // believed they had been delivered. Give them
                            // back, and say so.
                            debugPrint('unlink send failed: $e');
                            composer.text = text;
                            setSheet(() {});
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    "That didn't send. Your words are still "
                                    'here — try again.',
                                  ),
                                ),
                              );
                            }
                          }
                        },
                        icon: const Icon(
                          Icons.arrow_upward_rounded,
                          color: MilesColors.ember,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    composer.dispose();
  }

  bool mineOf(UnlinkRow row) =>
      row.iAmInitiator(ref.read(currentProfileProvider)?.id ?? '');

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
            'Open the door',
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
    final partnerName =
        ref.watch(partnerProfileProvider)?.displayName ?? 'Your partner';

    if (DoorstepScene.fits(context)) {
      return _stageLayout(context, row, mine: mine, partnerName: partnerName);
    }
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
                              _headline(mine, partnerName),
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
                              _subline(mine),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: MilesColors.taupe,
                                fontSize: 15,
                                height: 1.45,
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          // The calm layout: animations off, or a text scale
                          // that needs the room. The stage lives in
                          // _stageLayout; here the words stand alone.
                          // The borrowed quote is gone by the owner's call:
                          // the companion is the only voice this ceremony
                          // needs, in both layouts.
                          if (mine &&
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
