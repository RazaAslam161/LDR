import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/services/session_scope.dart';
import 'package:miles/core/services/unread_tally.dart';
import 'package:miles/features/covers/news_cover_screen.dart';
import 'package:miles/features/disguise/cover_gate.dart';
import 'package:miles/features/disguise/covers/calculator_cover.dart';
import 'package:miles/features/disguise/covers/convert_cover.dart';
import 'package:miles/features/disguise/covers/device_info_cover.dart';
import 'package:miles/features/disguise/covers/level_cover.dart';
import 'package:miles/features/disguise/covers/notes_cover.dart';
import 'package:miles/features/disguise/covers/recorder_cover.dart';
import 'package:miles/features/disguise/covers/timer_cover.dart';
import 'package:miles/features/disguise/covers/weather_cover.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:miles/features/disguise/disguise_service.dart';
import 'package:miles/features/disguise/entry/cover_entry_scope.dart';
import 'package:miles/features/disguise/entry/cover_entry_store.dart';
import 'package:miles/features/disguise/entry/entry_trigger_layer.dart';

/// The cover that draws [cover].
///
/// One builder, used by the host and by the move recorder, so the owner's move
/// is recorded on exactly the widget it is later matched on. Every cover is a
/// plain fake app: none takes a callback, none knows a door exists.
Widget buildCoverWidget(DisguiseCover cover) => switch (cover) {
      // Nothing to draw. The identity IS the app, so the gate opens itself
      // and the user lands in Miles — which is what "no cover" has to mean,
      // or the launcher says one thing and the first screen says another.
      DisguiseCover.none => const SizedBox.shrink(),
      DisguiseCover.calculator => const CalculatorCover(),
      DisguiseCover.notes => const NotesCover(),
      DisguiseCover.weather => const WeatherCover(),
      DisguiseCover.convert => const ConvertCover(),
      DisguiseCover.recorder => const RecorderCover(),
      DisguiseCover.timer => const TimerCover(),
      DisguiseCover.level => const LevelCover(),
      DisguiseCover.device => const DeviceInfoCover(),
      DisguiseCover.news => const NewsCoverScreen(),
    };

/// The theme every cover renders under: a clean light stock look that shares
/// nothing with Miles's own. One function, because the recorder must draw the
/// cover exactly as the host does or a move recorded on one would not match
/// the other.
ThemeData coverHostTheme() => ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: Colors.white,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1A73E8)),
      useMaterial3: true,
    );

/// Renders the cover that matches the user's chosen launcher identity, and
/// owns every way through it.
///
/// The icon and the cover must agree. A Calculator icon that opens a news
/// reader is a louder signal than no disguise at all — it tells anyone who taps
/// it that the app is hiding something.
///
/// Resolved from SharedPreferences rather than passed down, because the very
/// first frame after a cold start is this widget and there is no session yet.
class DisguiseCoverHost extends StatefulWidget {
  const DisguiseCoverHost({required this.onAuthenticated, super.key});

  final VoidCallback onAuthenticated;

  @override
  State<DisguiseCoverHost> createState() => _DisguiseCoverHostState();
}

class _DisguiseCoverHostState extends State<DisguiseCoverHost>
    with WidgetsBindingObserver {
  DisguiseProfile? _profile;

  /// What is known about the rendered cover's recorded move.
  ///
  /// Starts at `customUnknown` — "there may be a move here" — and is only
  /// ever relaxed to `none` once both reads have actually said so. Starting
  /// at `none` meant the backup hold was unforced for as long as the
  /// identity took to resolve, and `reconcile()` is allowed to take three
  /// seconds and is allowed to hang. The strict side costs a fresh install
  /// nothing: with no PIN and no biometric the gate's own floor still lets
  /// the owner straight through.
  CoverEntryMode _mode = CoverEntryMode.customUnknown;

  late final CoverEntryController _entry = CoverEntryController(
    mode: EntryLayerMode.watch,
    onOpen: _enter,
  );

  /// Whether unread messages are waiting behind the cover.
  ///
  /// This is the compensation the cover-silence design promised: covers post
  /// NO notification (the shade header would say "Miles" — see
  /// showMessageNotification), so the only place an unread signal can live is
  /// the cover's own UI, where the OS cannot relabel it. Host-level rather
  /// than per-cover: one dot, one place, every cover, and a new cover gets it
  /// for free.
  ///
  /// Refreshed on mount and on resume, NOT polled: the only writer is the
  /// background push isolate, so the tally can only have changed while this
  /// process was away — a timer here would burn prefs reloads observing a
  /// value nothing foreground ever writes. Known limit, stated: a message
  /// arriving while someone is actively watching the cover surfaces on the
  /// next resume, because the foreground handler does not feed the tally.
  bool _hasUnread = false;

  @override
  void initState() {
    super.initState();
    // A fresh host means no entry flow can be in progress on its navigator;
    // a guard left set by a torn-down host would make every door inert.
    CoverEntry.entering = false;
    // A move is positions in a box. The activity itself is free to rotate,
    // so the cover pins portrait; the real app already returns to portrait
    // after its one landscape screen.
    unawaited(
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
    );
    WidgetsBinding.instance.addObserver(this);
    // The system doors, once for every cover: a tapped call notification and
    // an auth link both open the gate without a trigger, never without the
    // lock. Either may have arrived before this host was built.
    pendingCall.addListener(_openForPendingCall);
    pendingAuthLink.addListener(_openForAuthLink);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openForPendingCall();
      _openForAuthLink();
    });
    _refreshUnread();
    // The mode, as early as a prefs read allows and independent of the
    // identity: the cover being drawn is whatever reconcile() lands on, but
    // the question "is there a move on this phone at all" is answerable
    // before that, and the backup door reads it.
    unawaited(_resolveEntryEarly());
    // reconcile(), not current(): the cover screen is the first thing to run in
    // the foreground, which makes it the right place to repair a stored
    // identity that drifted from the alias Android actually enabled — and to
    // get the preference correct BEFORE the next push has to read it from the
    // background isolate.
    DisguiseService.reconcile()
        // Belt and braces over the timeouts inside reconcile(): whatever
        // happens, this future MUST complete or the user is stranded on a blank
        // screen with no way into the app.
        .timeout(const Duration(seconds: 3))
        .catchError((_) =>
            DisguiseService.plainDefault ? kPlainProfile : kDefaultDisguise)
        .then((d) {
      if (!mounted) return;
      // No cover means the app is its own front door. Opening the gate here
      // rather than drawing an empty box is what makes "Miles, no disguise"
      // behave like an ordinary app instead of a cover that happens to be
      // blank.
      if (d.cover == DisguiseCover.none) {
        widget.onAuthenticated();
        return;
      }
      setState(() => _profile = d);
      unawaited(_resolveEntry(d.cover));
    });
  }

  /// Before the identity is known: if NO cover on this phone has a move
  /// recorded, there is nothing to be strict about and the mode can relax to
  /// `none`. Any single record anywhere keeps it strict until [_resolveEntry]
  /// says which cover is worn.
  Future<void> _resolveEntryEarly() async {
    for (final cover in DisguiseCover.values) {
      if (cover == DisguiseCover.none) continue;
      if (await CoverEntryStore.present(cover)) return;
    }
    if (mounted && _profile == null) {
      setState(() => _mode = CoverEntryMode.none);
    }
  }

  /// The mirror first — a prefs read, as fast as the identity itself — so the
  /// backup hold knows to end at the PIN before the keystore has answered;
  /// then the payload, which is what the layer actually matches.
  Future<void> _resolveEntry(DisguiseCover cover) async {
    final present = await CoverEntryStore.present(cover);
    if (!mounted) return;
    setState(() => _mode =
        present ? CoverEntryMode.customUnknown : CoverEntryMode.none);
    final (mode, trigger) = await CoverEntryStore.resolve(cover);
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _entry.trigger = trigger;
    });
  }

  @override
  void dispose() {
    pendingCall.removeListener(_openForPendingCall);
    pendingAuthLink.removeListener(_openForAuthLink);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshUnread();
  }

  /// Open the door for an incoming call, without a trigger.
  ///
  /// A closed app woken by a call used to be unanswerable. The cover replaces
  /// the whole app while showRealApp is false, so the router — and with it the
  /// call route and the shell that listens for [pendingCall] — does not exist.
  /// The phone rang, the user opened the app, and saw a news reader with no way
  /// to reach the call before the caller gave up.
  ///
  /// The trigger is skipped, NOT the lock: the user already declared intent by
  /// tapping a call notification, but nothing about this app is revealed until
  /// they pass the same biometric as always. A shoulder-surfer sees the cover
  /// and a nameless system prompt, exactly as before.
  ///
  /// That premise only holds when the ring was actually tapped. A push arriving
  /// while the app is foregrounded goes to FcmService._onForeground, which
  /// posts no notification at all — so on a handset sitting on its cover the
  /// partner pressing Call used to replace the cover with the call screen,
  /// showing their avatar and real name, within a frame and with nothing
  /// tapped. So the door opens only on [CallTap.fromTap]; an untapped ring is
  /// left for the notification _onForeground posts instead.
  void _openForPendingCall() {
    final tap = pendingCall.value;
    if (CoverEntry.entering || tap == null || !tap.fromTap) return;
    _enter(EntrySource.system, forCall: true);
  }

  /// Open the door for an email confirmation or password-reset link.
  ///
  /// Reading the mail backgrounds this app, which drops it to the cover;
  /// tapping the link wakes it there. supabase_flutter redeems the token off
  /// that link and the session goes valid — behind a calculator, with nothing
  /// on screen to say so and, for a reset, no /new-password route in existence
  /// to push. Consumed on the first attempt rather than on success, so a
  /// failed biometric returns to the cover instead of re-prompting on every
  /// rebuild.
  void _openForAuthLink() {
    if (CoverEntry.entering || !pendingAuthLink.value) return;
    pendingAuthLink.value = false;
    _enter(EntrySource.system);
  }

  Future<void> _enter(EntrySource source, {bool forCall = false}) =>
      CoverEntry.run(
        context,
        onUnlocked: widget.onAuthenticated,
        source: source,
        mode: _mode,
        forCall: forCall,
      );

  Future<void> _refreshUnread() async {
    // The stored couple, not the session — the cover is the first frame of a
    // cold start and there is no session yet. Signed out means no couple,
    // which correctly means no dot: nothing to show and nothing to leak.
    final coupleId = await SessionScope.readCouple();
    final n = coupleId == null ? 0 : await UnreadTally.current(coupleId);
    if (mounted && (n > 0) != _hasUnread) {
      setState(() => _hasUnread = n > 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Never a blank screen. Reading the identity is a local disk hit that
    // normally resolves in the first frame or two; if it somehow does not, the
    // user still gets a working cover instead of an empty rectangle they cannot
    // escape. Rendering the DEFAULT cover leaks nothing — it is what a fresh
    // install shows anyway.
    // The pre-load fallback follows the CHANNEL, not the old default. On a
    // build that installs as Miles, showing News for the frame or two before
    // the identity loads is the same bug this whole change is about, just
    // briefer.
    final profile = _profile ??
        (DisguiseService.plainDefault ? kPlainProfile : kDefaultDisguise);

    final cover = buildCoverWidget(profile.cover);
    // ALWAYS the same tree, dot or no dot. Returning `cover` bare on one side
    // of the toggle changes the root widget type mid-flight, and Flutter
    // answers that by tearing down and re-inflating the entire cover subtree
    // — on the feature's most ordinary path (cold start with unread waiting,
    // the dot resolving one frame after the cover painted), losing any state
    // the cover held, typed calculator digits included.
    //
    // The dot itself: deliberately NOT a badge, a count or a color the
    // cover's own palette would never produce — an 8px mid-grey dot in the
    // bottom corner, readable only by someone who knows to look for it. The
    // owner learns it from the picker; a stranger sees screen furniture.
    return CoverEntryScope(
      controller: _entry,
      child: EntryTriggerLayer(
        controller: _entry,
        child: Stack(
          children: [
            cover,
            if (_hasUnread && profile.cover != DisguiseCover.none)
              const Positioned(
                key: ValueKey('coverUnreadDot'),
                right: 16,
                bottom: 28,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      // Opaque mid-grey: visible on the dark covers and the
                      // light ones, committed to neither — and opaque on
                      // purpose, the repo bans see-through fills.
                      color: Color(0xFF808080),
                    ),
                    child: SizedBox(width: 8, height: 8),
                  ),
                ),
              ),
            // A screen reader owns the touchscreen: raw pointers never reach
            // the layer, so neither the owner's move nor the backup hold can
            // fire under TalkBack. This is the backup door's accessible form,
            // drawn only while a reader is driving — no pixels, one node,
            // and it lands where the hold lands: on the PIN.
            if (MediaQuery.accessibleNavigationOf(context) &&
                profile.cover != DisguiseCover.none)
              Positioned(
                top: MediaQuery.paddingOf(context).top,
                left: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // Always the strict mode, never `_mode`: this node is
                  // announced by name to anyone who turns a screen reader on,
                  // so it may never be the one door that opens without a
                  // credential.
                  onTap: () => CoverEntry.run(
                    context,
                    onUnlocked: widget.onAuthenticated,
                    source: EntrySource.backup,
                    mode: CoverEntryMode.customUnknown,
                  ),
                  child: Semantics(
                    button: true,
                    label: 'Unlock',
                    child: const SizedBox(width: 56, height: 56),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
