import 'package:flutter/material.dart';
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

class _DisguiseCoverHostState extends State<DisguiseCoverHost> {
  DisguiseProfile? _profile;

  @override
  void initState() {
    super.initState();
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

    return switch (profile.cover) {
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
  }
}
