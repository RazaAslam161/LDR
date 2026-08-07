import 'package:flutter/material.dart';
import 'package:miles/features/disguise/covers/calculator_cover.dart';
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
    DisguiseService.current().then((d) {
      if (mounted) setState(() => _profile = d);
    });
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    // Until the choice is read, show nothing rather than guessing — a flash of
    // the wrong cover would leak which disguise is real.
    if (profile == null) {
      return const ColoredBox(color: Colors.white, child: SizedBox.expand());
    }

    return switch (profile.cover) {
      DisguiseCover.calculator =>
        CalculatorCover(onAuthenticated: widget.onAuthenticated),
      // notes/weather are unreachable today — kDisguises does not offer them
      // until they have covers of their own. The news reader is the safe
      // fallback if one is ever selected before its cover lands.
      DisguiseCover.news ||
      DisguiseCover.notes ||
      DisguiseCover.weather =>
        FakeNewsScreen(onAuthenticated: widget.onAuthenticated),
    };
  }
}
