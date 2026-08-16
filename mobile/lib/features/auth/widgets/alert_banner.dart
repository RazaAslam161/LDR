import 'package:flutter/material.dart';

import 'package:miles/core/ui/theme.dart';

enum AlertTone { error, info }

/// A form-level message: something failed, or something was sent.
///
/// It appears in response to an action the user just took, which is precisely
/// the case a screen reader cannot discover on its own — the visual user sees a
/// red box arrive, and everyone else gets silence and an unchanged screen. It
/// is a live region now, so the message is announced when it appears.
///
/// The colours were two hard-coded hexes that belonged to no palette:
/// `0xFFEF6F58` for error against the theme's own `0xFFE5736B`, and
/// `0xFF34D399` — a mint green — in an app whose success colour is
/// `MilesColors.sage`. Both now come from the scheme, so a theme change moves
/// them.
class AlertBanner extends StatelessWidget {
  const AlertBanner({
    required this.message, super.key,
    this.tone = AlertTone.error,
  });
  final String message;
  final AlertTone tone;

  @override
  Widget build(BuildContext context) {
    final isError = tone == AlertTone.error;
    final color =
        isError ? Theme.of(context).colorScheme.error : MilesColors.sage;

    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: MilesColors.tint(color, 0.12, over: MilesColors.night),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.check_circle_outline,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                // 13px hard-coded before, which ignored the user's text scale
                // on the one string that explains why they cannot get in.
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
