import 'package:flutter/material.dart';
import 'package:miles/core/services/session_scope.dart';
import 'package:miles/core/services/unread_tally.dart';
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
import 'package:miles/features/covers/news_cover_screen.dart';

/// Renders the cover that matches the user's chosen launcher identity.
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
    WidgetsBinding.instance.addObserver(this);
    _refreshUnread();
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
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshUnread();
  }

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

    final cover = switch (profile.cover) {
      // Nothing to draw. The identity IS the app, so the gate opens itself and
      // the user lands in Miles — which is what "no cover" has to mean, or the
      // launcher says one thing and the first screen says another.
      DisguiseCover.none => const SizedBox.shrink(),
      DisguiseCover.calculator =>
        CalculatorCover(onAuthenticated: widget.onAuthenticated),
      DisguiseCover.notes =>
        NotesCover(onAuthenticated: widget.onAuthenticated),
      DisguiseCover.weather =>
        WeatherCover(onAuthenticated: widget.onAuthenticated),
      DisguiseCover.convert =>
        ConvertCover(onAuthenticated: widget.onAuthenticated),
      DisguiseCover.recorder =>
        RecorderCover(onAuthenticated: widget.onAuthenticated),
      DisguiseCover.timer =>
        TimerCover(onAuthenticated: widget.onAuthenticated),
      DisguiseCover.level =>
        LevelCover(onAuthenticated: widget.onAuthenticated),
      DisguiseCover.device =>
        DeviceInfoCover(onAuthenticated: widget.onAuthenticated),
      DisguiseCover.news =>
        NewsCoverScreen(onAuthenticated: widget.onAuthenticated),
    };
    // ALWAYS the Stack, dot or no dot. Returning `cover` bare on one side of
    // the toggle changes the root widget type mid-flight, and Flutter answers
    // that by tearing down and re-inflating the entire cover subtree — on the
    // feature's most ordinary path (cold start with unread waiting, the dot
    // resolving one frame after the cover painted), losing any state the
    // cover held, typed unlock digits included.
    //
    // The dot itself: deliberately NOT a badge, a count or a color the
    // cover's own palette would never produce — an 8px mid-grey dot in the
    // bottom corner, readable only by someone who knows to look for it. The
    // owner learns it from the picker; a stranger sees screen furniture. The
    // exit ring is already the one disclosed affordance every cover carries —
    // this stays quieter than the ring.
    return Stack(
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
                  // Opaque mid-grey: visible on the dark covers and the light
                  // ones, committed to neither — and opaque on purpose, the
                  // repo bans see-through fills.
                  color: Color(0xFF808080),
                ),
                child: SizedBox(width: 8, height: 8),
              ),
            ),
          ),
      ],
    );
  }
}
