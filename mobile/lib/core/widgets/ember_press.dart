import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/ui/motion.dart';

/// EmberPress — the one way a custom surface acknowledges a touch
/// (design-system.md §5, adapted: the spec's press-glow animated a shadow and
/// a gradient, both banned properties, so the acknowledgment is scale and
/// haptic alone).
///
/// Scale 1 → 0.97 in [MilesMotion.instant] on contact, back over
/// [MilesMotion.quick] on release. Pointer hover (a mouse or stylus — the
/// nearest thing Android has to hover) and keyboard focus lift to 1.015.
/// Transform only, one controller, and with animations off the child never
/// scales but every tap still lands and still clicks.
///
/// [onCue] is a seam, not a dependency: the sound layer (when it lands)
/// passes its cue callback here, and this widget stays free of any audio
/// import.
class EmberPress extends StatefulWidget {
  const EmberPress({
    required this.child,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.haptic = true,
    this.onCue,
    this.pressedScale = 0.97,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool enabled;
  final bool haptic;
  final VoidCallback? onCue;
  final double pressedScale;

  @override
  State<EmberPress> createState() => _EmberPressState();
}

class _EmberPressState extends State<EmberPress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: MilesMotion.instant,
    reverseDuration: MilesMotion.quick,
  );
  bool _hovered = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool get _tappable =>
      widget.enabled && (widget.onTap != null || widget.onLongPress != null);

  void _down(TapDownDetails _) {
    if (!_tappable) return;
    if (widget.haptic) HapticFeedback.lightImpact();
    if (!MilesMotion.off(context)) _ctrl.forward();
  }

  void _release() {
    // A mid-press off-flip must not start a reverse ticker: snap home.
    if (MilesMotion.off(context)) {
      _ctrl.value = 0;
      return;
    }
    // Inside a scrollable, a fast tap delivers onTapDown and onTapUp
    // back-to-back at pointer-up (the arena held the down until the press
    // deadline), so a plain reverse() from ~0 meant the haptic clicked while
    // the 0.97 scale never painted a frame. Let the press-in complete first —
    // the round trip stays inside instant + quick.
    if (_ctrl.status == AnimationStatus.forward) {
      _ctrl.forward().whenComplete(() {
        if (mounted && !MilesMotion.off(context)) _ctrl.reverse();
      });
    } else if (_ctrl.value > 0) {
      _ctrl.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final off = MilesMotion.off(context);
    return Semantics(
      button: _tappable,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          // Opaque only when this pressable actually does something: a
          // disabled instance must not claim and swallow taps that belong to
          // whatever sits behind it.
          behavior: _tappable
              ? HitTestBehavior.opaque
              : HitTestBehavior.deferToChild,
          onTapDown: _down,
          onTapUp: (_) => _release(),
          onTapCancel: _release,
          onTap: _tappable
              ? () {
                  widget.onCue?.call();
                  widget.onTap?.call();
                }
              : null,
          onLongPress: widget.enabled ? widget.onLongPress : null,
          child: AnimatedScale(
            scale: _hovered && !off ? 1.015 : 1.0,
            // Duration.zero when off: ImplicitlyAnimatedWidget never consults
            // disableAnimations itself, and a cursor resting here when the
            // setting flips would otherwise play a visible 220ms shrink.
            duration: off ? Duration.zero : MilesMotion.quick,
            curve: MilesMotion.enter,
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (context, child) {
                final pressed = MilesMotion.enter.transform(_ctrl.value);
                final scale =
                    off ? 1.0 : 1.0 - (1.0 - widget.pressedScale) * pressed;
                return Transform.scale(scale: scale, child: child);
              },
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
