import 'package:flutter/material.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';

/// The one page shell every auth and onboarding screen sits in.
///
/// Each of these screens had built its own: its own padding, its own back
/// button, its own idea of how big a title is, and — because `Scaffold` alone
/// does not draw the candle glow — some of them had the ember field behind them
/// and some did not. Sign-in and sign-up were flat black while the splash and
/// pairing screens glowed, which is the join between them, i.e. the first four
/// screens anyone ever sees.
///
/// It also owns the two things that are wrong on a phone rather than on a
/// laptop, and were wrong on every one of these screens:
///
///   * The keyboard. A `SingleChildScrollView` inside `SafeArea` does not add
///     bottom inset for the IME, so on a short screen the focused field sat
///     under the keyboard with nothing to scroll to. `viewInsets.bottom` is
///     added to the padding here, once, for all of them.
///   * The back affordance. A bare `TextButton` in a leading slot is ~20dp of
///     real target. Android asks for 48dp, and this is the control someone
///     reaches for when they have typed the wrong thing.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    required this.title,
    required this.children,
    super.key,
    this.subtitle,
    this.onBack,
    this.trailing,
    this.centred = false,
  });

  /// Display heading. Rendered from the type scale, never a hand-set size.
  final String title;

  /// One line under the title saying what this screen is for.
  final String? subtitle;

  /// Back affordance. Omitted entirely when null — a screen with no way back
  /// should show no control, rather than one that does nothing.
  final VoidCallback? onBack;

  /// Optional top-right action (pairing puts "Sign out" here, because the
  /// router will not let an unpaired account reach settings any other way).
  final Widget? trailing;

  /// Vertically centre the content instead of starting it below the title.
  /// Used by the short screens (new password) so they do not float at the top
  /// of a tall display.
  final bool centred;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final media = MediaQuery.of(context);

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // A heading is the screen's name to a screen reader, not decoration.
        Semantics(
          header: true,
          child: Text(title, style: text.displaySmall),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          Text(subtitle!, style: text.bodyMedium),
        ],
        const SizedBox(height: 28),
        ...children,
      ],
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: EmberBackground(
        child: SafeArea(
          child: Column(
            children: [
              if (onBack != null || trailing != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Row(
                    children: [
                      if (onBack != null)
                        IconButton(
                          onPressed: onBack,
                          icon: const Icon(Icons.arrow_back),
                          color: MilesColors.gilt,
                          // Explicit, because IconButton's default varies with
                          // visualDensity and this one must clear 48dp on the
                          // small-screen devices where it matters most.
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                          tooltip: 'Back',
                        ),
                      const Spacer(),
                      if (trailing != null) trailing!,
                    ],
                  ),
                ),
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    24,
                    onBack == null && trailing == null ? 32 : 8,
                    24,
                    // The keyboard, plus room to breathe under the last control.
                    24 + media.viewInsets.bottom,
                  ),
                  child: centred
                      ? ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: media.size.height * 0.6,
                          ),
                          child: Center(child: body),
                        )
                      : body,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "New here? Create an account" line at the foot of sign-in and sign-up.
///
/// It was a `GestureDetector` around a `Text` on both screens: no ripple, no
/// focus ring, no semantics beyond the words, and about twenty logical pixels
/// of height to hit. A `TextButton` is the same sentence with a real target,
/// a pressed state and a role a screen reader can announce.
class AuthSwitchLink extends StatelessWidget {
  const AuthSwitchLink({
    required this.prompt,
    required this.action,
    required this.onPressed,
    super.key,
  });

  final String prompt;
  final String action;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            prompt,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.end,
          ),
        ),
        TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          child: Text(action),
        ),
      ],
    );
  }
}
