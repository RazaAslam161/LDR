import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/ui/theme.dart';

/// A destructive confirm that costs attention rather than time.
///
/// The account-deletion dialog asks for a typed DELETE; remove-partner asked
/// for nothing at all, which is how the app came to confirm deleting your
/// account harder than it confirms destroying the relationship.
///
/// Typing is the wrong correction. It is six to ten seconds of two-handed work,
/// and the one thing this control must never do is make leaving slower for
/// someone who needs to leave right now. A hold is one-handed and just as fast
/// under fear as a tap is; what it cannot survive is a rage-mash or a fumbled
/// double-tap, because those spend no sustained attention. That is the only
/// currency anger has and fear does not, so it is the only one worth charging.
class HoldToConfirm extends StatefulWidget {
  const HoldToConfirm({
    required this.label,
    required this.holdingLabel,
    super.key,
    this.onConfirmed,
    this.duration = const Duration(milliseconds: 1200),
    this.color = MilesColors.danger,
  });

  /// At rest.
  final String label;

  /// While the press is down. Says the thing is happening, not that it might.
  final String holdingLabel;

  /// Null disables the control, matching every other button in the app.
  final VoidCallback? onConfirmed;

  /// 1200ms sits above a fumble (~300ms) and below the point where it reads as
  /// the app arguing with you. There is no telemetry in this app to tune it
  /// against and no way to A/B it on a two-user install, so it is a judgement.
  final Duration duration;

  final Color color;

  @override
  State<HoldToConfirm> createState() => _HoldToConfirmState();
}

class _HoldToConfirmState extends State<HoldToConfirm>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..addStatusListener(_onStatus);

  /// One fire per hold, not one per lifetime.
  ///
  /// The controller can reach `completed` more than once while the finger stays
  /// down across a rebuild, and this fires an irreversible action, so the latch
  /// is necessary. Clearing it on `dismissed` — the fill fully drained after a
  /// release — is equally necessary and is easy to leave out: latch forever and
  /// a failed attempt leaves the sheet saying "Try again" above a control that
  /// can no longer do anything.
  bool _fired = false;

  void _onStatus(AnimationStatus s) {
    if (s == AnimationStatus.dismissed) {
      _fired = false;
      return;
    }
    if (s != AnimationStatus.completed || _fired) return;
    _fired = true;
    // Confirmation you can feel. The screen is about to be replaced, so
    // there may be nothing left to look at by the time this lands.
    HapticFeedback.mediumImpact();
    widget.onConfirmed?.call();
  }

  @override
  void dispose() {
    _c
      ..removeStatusListener(_onStatus)
      ..dispose();
    super.dispose();
  }

  bool get _enabled => widget.onConfirmed != null;

  /// Gated on the latch as well, so a hold that has already fired cannot fire
  /// again without being released first.
  bool get _canStart => _enabled && !_fired;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: _canStart ? (_) => _c.forward() : null,
      // Release stays wired even after firing, and that is load-bearing: gate
      // it on the latch too and a fired control can never drain, so `dismissed`
      // never arrives, so the latch never clears — a deadlock that looks
      // exactly like a disabled button.
      onTapUp: _enabled ? (_) => _c.reverse() : null,
      onTapCancel: _enabled ? () => _c.reverse() : null,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final holding = _c.value > 0;
          return Container(
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: widget.color.withValues(alpha: 0.55)),
              // Resolved against the sheet it sits on rather than left
              // translucent: this is a surface with a label read off it,
              // and the repo gate is right that those must be opaque.
              color: MilesColors.tint(widget.color, _enabled ? 0.12 : 0.05),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // The fill is the whole affordance: it tells you a hold is
                // what is wanted, and how much of it is left.
                Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: _c.value,
                    heightFactor: 1,
                    child: ColoredBox(
                      color: widget.color.withValues(alpha: 0.85),
                    ),
                  ),
                ),
                Text(
                  holding ? widget.holdingLabel : widget.label,
                  style: TextStyle(
                    color: _enabled
                        ? MilesColors.cream50
                        : MilesColors.cream50.withValues(alpha: 0.4),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
