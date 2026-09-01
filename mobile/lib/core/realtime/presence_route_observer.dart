import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';

/// Publishes "which screen am I on" — the single place that answers it.
///
/// Presence used to be reported by hand from each screen's initState, and only
/// 13 of 44 routes ever did it. Walking into any of the other 31 left the
/// partner's device showing wherever you were LAST — not stale for a few
/// seconds, but wrong until you happened to open a screen that did report.
///
/// In a couples app that is not a cosmetic bug. "She's still in the chat" when
/// she is not manufactures a story out of a missing function call, so this must
/// hold for every route including ones nobody has written yet. Hooking the
/// navigator makes correctness the default: a new screen reports because it
/// exists, not because someone remembered.
///
/// The bottom-nav tabs are the one move the navigator cannot see — switching
/// tabs is a setState, not a route — so [publishActiveTab] exists for AppShell.
/// Everything else comes through here, and nothing else writes the value: two
/// publishers with two ideas of what was last said is how this went wrong the
/// first time.
class PresenceRouteObserver extends NavigatorObserver {
  PresenceRouteObserver(this._ref);

  final Ref _ref;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _report(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _report(newRoute);

  /// On pop the destination is where the user now IS — report that, not the
  /// screen being torn down.
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _report(previousRoute);

  /// Deliberately silent. `previousRoute` here is the route BELOW the one being
  /// removed, which is only where the user now is when the removed route was on
  /// top. `pushReplacement` removes a route with a survivor beneath it, and
  /// reporting that survivor announced the capsule LIST while the user was
  /// reading a capsule — and offered their partner a join that landed there.
  ///
  /// Every removal in this app arrives after the push that caused it, so the
  /// destination has already been reported by the time we get here. Nothing is
  /// lost by staying quiet.
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {}

  void _report(Route<dynamic>? route) {
    // Nothing underneath. Not "an unknown room" — no room at all, which is what
    // didRemove reports when the bottom of the stack goes. A go() to a sibling
    // route pushes the new page and THEN removes the old bottom, so publishing
    // here would blank out the room we just arrived in.
    if (route == null) return;

    // Dialogs, sheets and menus sit on top of a room rather than being one.
    // Only full pages change where somebody is.
    if (route is! PageRoute) return;

    final path = route.settings.name;
    if (path == null) {
      // A page pushed without a name — eleven places still use a bare
      // MaterialPageRoute. We genuinely do not know what room this is, and
      // going on claiming the previous one is exactly the lie this class exists
      // to stop. "Somewhere" is honest; "still in the chat" is not.
      publish(null);
      return;
    }

    // The tab shell is not a room; the selected tab is. Landing back on it —
    // popping out of a pushed screen, or out of an unnamed one — has to restore
    // the tab, or presence stays blank until the user taps the nav bar.
    if (path == '/app') {
      publishActiveTab();
      return;
    }

    final name = screenNameForPath(path);
    // A named route that is deliberately not a place (auth, the capture camera)
    // leaves the current value alone — nobody has moved rooms.
    if (name == null) return;
    publish(name);
  }

  /// Publish the bottom-nav tab the user is on. The navigator cannot see a tab
  /// change, so AppShell calls this directly.
  void publishActiveTab() {
    // Identity maps to its label directly — no index, no flag alignment to
    // get wrong. An unknown identity publishes Home, the shell's own answer.
    final label = switch (_ref.read(shellTabProvider)) {
      'chat' => 'Chat',
      'touch' => 'Touch',
      'closer' => 'Closer',
      _ => 'Home',
    };
    publish(label, src: 'tab');
  }

  /// Publish [name] as the room this user is in, or null for "somewhere".
  ///
  /// [src] only labels the trace — a tab switch, a route change and a resume
  /// arrive here identically otherwise, and the three fail differently.
  void publish(String? name, {String src = 'route'}) {
    // Navigator observers fire while the tree is being built, and Riverpod
    // refuses a write during that phase. Deferring only when we really are
    // mid-frame keeps the common path synchronous.
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase != SchedulerPhase.persistentCallbacks &&
        phase != SchedulerPhase.midFrameMicrotasks) {
      // Writing now supersedes anything a flush is still holding, or that
      // stale value would land afterwards and undo this.
      _pending = name;
      _pendingSrc = src;
      _write(name, src);
      return;
    }

    // One frame can produce several of these — a go() pushes and removes, a
    // redirect replaces. Keep only the last and write it once, so the order
    // they arrived in cannot matter and a stale read cannot swallow one.
    _pending = name;
    _pendingSrc = src;
    if (_flushScheduled) return;
    _flushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _flushScheduled = false;
      _write(_pending, _pendingSrc);
    });
  }

  /// The room this frame ended on, waiting to be written.
  String? _pending;
  String _pendingSrc = 'route';
  bool _flushScheduled = false;

  /// The last screen that actually REACHED the database.
  ///
  /// The dedupe used to compare against myScreenProvider, which is set for the
  /// local badge before the couple is even known. A publish made during the
  /// couple-null window therefore wrote nothing, recorded itself as the current
  /// screen anyway, and then suppressed every later publish of that same room —
  /// permanently, until the user happened to navigate somewhere else.
  ///
  /// Captured in the field: three rows, has_couple:false/wrote_db:false twice,
  /// then deduped:true/wrote_db:false once the couple returned.
  ///
  /// So the two facts are stored separately now. The provider is what this
  /// device shows; this is what the partner has been told. Only the second one
  /// can justify skipping a write.
  String? _lastWritten;
  bool _everWritten = false;

  void _write(String? name, String src) {
    if (_everWritten && name == _lastWritten) {
      Diag.record(DiagArea.presence, 'presence_screen_publish', fields: {
        'src': src,
        'has_name': name != null,
        'deduped': true,
        'has_couple': _ref.read(currentCoupleProvider) != null,
        'wrote_db': false,
        'announced': false,
      },);
      return;
    }

    // The local badge should not wait on the couple row to load.
    _ref.read(myScreenProvider.notifier).state = name;

    final couple = _ref.read(currentCoupleProvider);
    if (couple == null) {
      // Held, not dropped. The session goes null on every resume - seven
      // heartbeats were skipped across three and a half minutes in one traced
      // session - and whatever room the user is in has to survive that window.
      // flushDeferred() replays it the moment a couple exists.
      _deferred = name;
      _hasDeferred = true;
      Diag.record(DiagArea.presence, 'presence_screen_publish', fields: {
        'src': src,
        'has_name': name != null,
        'deduped': false,
        'has_couple': false,
        'wrote_db': false,
        'announced': false,
        'deferred': true,
      },);
      return;
    }

    // Durable value for a partner who opens the app later...
    PresenceService.setScreen(couple.id, name);
    // ...and the instant broadcast for one who is already looking.
    _ref.read(partnerScreenProvider.notifier).announce(name);
    // Only now. Recording it before the write is what made a failed publish
    // look like a successful one to every publish after it.
    _lastWritten = name;
    _everWritten = true;
    _hasDeferred = false;
    Diag.record(DiagArea.presence, 'presence_screen_publish', fields: {
      'src': src,
      'has_name': name != null,
      'deduped': false,
      'has_couple': true,
      'wrote_db': true,
      'announced': true,
    },);
  }

  /// A screen held back because there was no couple to tell.
  String? _deferred;
  bool _hasDeferred = false;

  /// Replay whatever the couple-null window swallowed.
  ///
  /// Called when a couple appears. Without it the user sits in a room their
  /// partner cannot see until they navigate somewhere else — which, on a phone
  /// left open on one screen, is never.
  void flushDeferred() {
    if (!_hasDeferred) return;
    final name = _deferred;
    _hasDeferred = false;
    Diag.record(DiagArea.presence, 'presence_screen_publish',
        fields: {'src': 'couple_ready', 'has_name': name != null},);
    _write(name, 'couple_ready');
  }

  /// The room we were in when the app went to the background, kept so
  /// [restore] can put the user back in it.
  String? _cleared;

  /// Clears the published screen — used when the app leaves the foreground, so
  /// a backgrounded user never reads as sitting in a room they have left.
  void clear() {
    _cleared = _ref.read(myScreenProvider);
    _write(null, 'clear');
  }

  /// Forget everything remembered about the identity that just left.
  ///
  /// Every field below is process-scoped, and so is this observer: it is built
  /// once inside buildRouter and nothing ever invalidates the provider that
  /// holds it, so one instance serves every account that signs in on the
  /// handset. The dedupe was therefore answering for the WRONG person — the
  /// first room the next account lands on matches the last room the previous
  /// one published, so [_write] returns before telling anybody, and that
  /// couple's presence row keeps whatever the previous session left in it until
  /// the new user happens to navigate elsewhere. Their partner, sitting in the
  /// same room, is never told they arrived.
  ///
  /// [_deferred] is the same fault one step later: a room held through a
  /// couple-null window under one identity would be replayed into the next
  /// one's row by [flushDeferred].
  ///
  /// Called from SessionNotifier.endCouple, which is the single door every
  /// sign-out and unlink goes through.
  void reset() {
    // Emptied, not cancelled: a flush scheduled for this frame still runs, and
    // it must publish "no room" rather than the room the departing identity was
    // standing in — which would re-arm the dedupe a frame after this cleared it
    // and hand the next account exactly the bug above. Clearing _flushScheduled
    // instead would let a second callback be scheduled beside the pending one.
    _pending = null;
    _pendingSrc = 'session_end';
    _lastWritten = null;
    _everWritten = false;
    _deferred = null;
    _hasDeferred = false;
    _cleared = null;
  }

  /// Puts the user back in the room they were in before the app was
  /// backgrounded.
  ///
  /// Without this, coming back leaves them invisible until they happen to
  /// navigate — and since attaching a photo or opening the camera pauses the
  /// app, that is most of a session. Worse than invisible, actually: their own
  /// badge would offer to take them to the room they are already standing in.
  void restore() {
    final room = _cleared;
    _cleared = null;
    if (room != null) publish(room, src: 'restore');
  }
}

/// Where to send someone who taps "join them".
///
/// The inverse of [screenNameForPath], and deliberately an explicit table
/// rather than a derived guess: pushing a route that does not exist throws, and
/// pushing the WRONG one lands the user somewhere private they did not ask for.
/// A name that is not listed here simply is not joinable, which is the safe
/// default — the tab screens are joinable via [joinableTabIndex] instead, since
/// they are not routes of their own.
const Map<String, String> kJoinableRoutes = {
  'Reasons': '/app/reasons',
  'Care': '/app/care',
  'Watch': '/app/watch',
  'Cycle': '/app/cycle',
  'Heartbeat': '/app/heartbeat',
  'Games': '/app/games',
  'Rituals': '/app/rituals',
  'Prompt': '/app/prompt',
  'Timeline': '/app/timeline',
  'Capsule': '/app/capsule',
};

/// Tab screens live inside the shell, so joining one means selecting its tab
/// rather than pushing a route: the nav index per tab, given which optional
/// tabs this build is showing.
///
/// NOT a const map. Touch sits in the middle of the bar and is hidden while
/// modest mode is on, which slides Closer down one — a fixed 'Closer': 4 was
/// landing on the right tab only because the shell clamps an out-of-range
/// index, and a clamp that happens to be correct is a bug waiting for someone
/// to add a tab. Camera is index 2 and has no body; every index past it counts
/// it anyway, because it is a real destination in the bar.

/// The route to push to join [screenName], or null if it is not joinable.
///
/// Intentionally refuses anything private or transient — the vault, the
/// disguise picker, settings, an active call — because "she's in the vault" is
/// not an invitation, and following her there would be a betrayal of the one
/// place in the app that is meant to be hers alone.
String? joinableRouteFor(String? screenName) =>
    screenName == null ? null : kJoinableRoutes[screenName];

/// The shell tab IDENTITY to select to join [screenName], or null.
///
/// Identity, not a bar index: an index is only meaningful against the exact
/// flag set the bar was built with, and the badge asking with stale flags
/// offered a join into the wrong room. The shell resolves identity against
/// its own current flags, so this needs none.
String? joinableTabIdentity(String? screenName) => switch (screenName) {
      'Home' => 'home',
      'Chat' => 'chat',
      'Touch' => 'touch',
      'Closer' => 'closer',
      _ => null,
    };

/// Human-facing name for a route, derived from its path.
///
/// Derived rather than hand-maintained: a per-route table is exactly the thing
/// that goes stale when someone adds a screen, which is how this broke.
/// Returns null for routes that are not a "place" the partner should see —
/// auth, the shell container itself, and the camera (a capture action, not a
/// room).
String? screenNameForPath(String path) {
  const notAPlace = {
    '/',
    '/signin',
    '/signup',
    '/welcome',
    '/couple',
    '/role-setup',
    '/app/rapid-camera', // a capture action, not somewhere you linger
    // A failed profile load, not a room — publishing it would tell the
    // partner "Offline" as if it were a place being visited.
    '/offline',
    '/terms', // a legal gate is not a place
    '/rewrap', // a key ceremony is not a place
    // A call is not a room either, and publishing it was a presence oracle in
    // both directions. The CALLER pushes /call at CallState.calling, which is
    // set before the offer is sent and up to ~15s before it on a cold relay
    // (call_controller.dart:724 vs :756) — so the callee's Home could read "In
    // Call" before the phone rang, and still read it when the ring never
    // arrived. The CALLEE pushes it at CallState.ringing (:803), before accept
    // or decline, and decline() never retracts it: declining told the caller
    // the app was open and the ring was seen, which is precisely what a call
    // attempt must not reveal.
    //
    // Note this is the publish side only. 'Call' was already refused by the
    // JOIN allowlist (kJoinableRoutes), and that asymmetry — an explicit
    // allowlist for joining, an implicit allow-everything for publishing — is
    // why this went unnoticed.
    '/call',
    // The tab shell. WHICH tab is not derivable from the path, so
    // PresenceRouteObserver answers that one from the selected index.
    '/app',
  };
  if (notAPlace.contains(path)) return null;

  final segments =
      path.split('/').where((s) => s.isNotEmpty && s != 'app').toList();
  if (segments.isEmpty) return null;

  // '/app/closer/memory-threads' -> 'Memory Threads'. The deepest segment is
  // the screen.
  return segments.last
      .split('-')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}
