import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/providers.dart';
import 'package:miles/core/screen_presence.dart';
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

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _report(previousRoute);

  void _report(Route<dynamic>? route) {
    // Dialogs, sheets and menus sit on top of a room rather than being one.
    // Only full pages change where somebody is.
    if (route != null && route is! PageRoute) return;

    final path = route?.settings.name;
    if (path == null) {
      // A page pushed without a name — a dozen places still use a bare
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
    final i = _ref.read(shellTabProvider).clamp(0, kTabScreens.length - 1);
    publish(kTabScreens[i]);
  }

  /// Publish [name] as the room this user is in, or null for "somewhere".
  void publish(String? name) {
    // The provider is the record of what was last said — not a private field.
    // A field drifts the moment anything else sets the value, which is exactly
    // what used to leave a tab unpublishable after a pop.
    if (name == _ref.read(myScreenProvider)) return;

    // Navigator observers fire while the tree is being built, and Riverpod
    // refuses a write during that phase. Deferring only when we really are
    // mid-frame keeps the common path synchronous.
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _write(name));
    } else {
      _write(name);
    }
  }

  void _write(String? name) {
    if (name == _ref.read(myScreenProvider)) return;

    // Our own value first: it is what this device's badge compares against, and
    // it should not wait on the couple row to finish loading.
    _ref.read(myScreenProvider.notifier).state = name;

    final couple = _ref.read(currentCoupleProvider);
    if (couple == null) return; // nobody to tell yet

    // Durable value for a partner who opens the app later...
    PresenceService.setScreen(couple.id, name);
    // ...and the instant broadcast for one who is already looking.
    _ref.read(partnerScreenProvider.notifier).announce(name);
  }

  /// Clears the published screen — used when the app leaves the foreground, so
  /// a backgrounded user never reads as sitting in a room they have left.
  ///
  /// Writes straight through rather than deferring: this runs from a lifecycle
  /// callback, and on `detached` there may be no further frame to defer to.
  void clear() {
    _ref.read(myScreenProvider.notifier).state = null;

    final couple = _ref.read(currentCoupleProvider);
    if (couple == null) return;
    PresenceService.setScreen(couple.id, null);
    _ref.read(partnerScreenProvider.notifier).announce(null);
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
  'Touch': '/app/touch',
  'Together': '/app/together',
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
  'Intimacy': '/app/intimacy',
};

/// Tab screens live inside the shell, so joining one means selecting its tab
/// rather than pushing a route. Index matches [kTabScreens].
const Map<String, int> kJoinableTabs = {
  'Home': 0,
  'Chat': 1,
  'Breath': 3,
  'Closer': 4,
};

/// The route to push to join [screenName], or null if it is not joinable.
///
/// Intentionally refuses anything private or transient — the vault, the
/// disguise picker, settings, an active call — because "she's in the vault" is
/// not an invitation, and following her there would be a betrayal of the one
/// place in the app that is meant to be hers alone.
String? joinableRouteFor(String? screenName) =>
    screenName == null ? null : kJoinableRoutes[screenName];

/// The shell tab index to select to join [screenName], or null.
int? joinableTabIndex(String? screenName) =>
    screenName == null ? null : kJoinableTabs[screenName];

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
    // The tab shell. WHICH tab is not derivable from the path, so
    // PresenceRouteObserver answers that one from the selected index.
    '/app',
  };
  if (notAPlace.contains(path)) return null;

  final segments =
      path.split('/').where((s) => s.isNotEmpty && s != 'app').toList();
  if (segments.isEmpty) return null;

  // '/app/closer/body-map' -> 'Body Map'. The deepest segment is the screen.
  return segments.last
      .split('-')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}
