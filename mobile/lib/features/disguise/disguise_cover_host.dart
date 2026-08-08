import 'package:flutter/material.dart';
import 'package:miles/features/disguise/covers/calculator_cover.dart';
import 'package:miles/features/disguise/covers/notes_cover.dart';
import 'package:miles/features/disguise/covers/weather_cover.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:miles/features/disguise/disguise_service.dart';
import 'package:miles/features/fake_news/fake_news_screen.dart';

/// Renders the cover that matches the user's chosen launcher identity.
///
/// The icon and the cover must agree. A Calculator icon that opens a news
/// reader is a louder signal than no disguise at all — it tells anyone who taps
/// it that the app is hiding something.
///
/// Resolved from SharedPreferences rather than passed down, because the very
/// first frame after a cold start is this widget and there is no session yet.
class DisguiseCoverHost extends StatefulWidget {
  const DisguiseCoverHost({super.key, required this.onAuthenticated});

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
        .catchError((_) => kDefaultDisguise)
        .then((d) {
      if (mounted) setState(() => _profile = d);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Never a blank screen. Reading the identity is a local disk hit that
    // normally resolves in the first frame or two; if it somehow does not, the
    // user still gets a working cover instead of an empty rectangle they cannot
    // escape. Rendering the DEFAULT cover leaks nothing — it is what a fresh
    // install shows anyway.
    final profile = _profile ?? kDefaultDisguise;

    return switch (profile.cover) {
      DisguiseCover.calculator =>
        CalculatorCover(onAuthenticated: widget.onAuthenticated),
      DisguiseCover.notes =>
        NotesCover(onAuthenticated: widget.onAuthenticated),
      DisguiseCover.weather =>
        WeatherCover(onAuthenticated: widget.onAuthenticated),
      DisguiseCover.news =>
        FakeNewsScreen(onAuthenticated: widget.onAuthenticated),
    };
  }
}
