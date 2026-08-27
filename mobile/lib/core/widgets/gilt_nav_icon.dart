import 'package:flutter/material.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/ui/theme.dart';

/// GiltSelect — the nav dock's selection moment (design-system.md §5). The
/// spec tweened the icon's colour gilt→ember; an animated colour repaints, so
/// the adaptation is two statically-coloured layers cross-fading — the same
/// read, compositor-only. The selected icon also lifts 2px, and a one-shot
/// gilt ring blooms outward and dies (scale + fade on a static border, the
/// exempt no-content decoration class).
class GiltNavIcon extends StatefulWidget {
  const GiltNavIcon({
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    super.key,
  });

  final Widget icon;
  final Widget selectedIcon;
  final bool selected;

  @override
  State<GiltNavIcon> createState() => _GiltNavIconState();
}

class _GiltNavIconState extends State<GiltNavIcon>
    with SingleTickerProviderStateMixin {
  // One controller runs both the cross-fade (its front ~third) and the
  // ring's longer bloom, as intervals of a single reveal-length run.
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: MilesMotion.reveal,
    value: widget.selected ? 1 : 0,
  );

  @override
  void didUpdateWidget(GiltNavIcon old) {
    super.didUpdateWidget(old);
    if (widget.selected == old.selected) return;
    if (MilesMotion.off(context)) {
      _ctrl.value = widget.selected ? 1 : 0;
    } else if (widget.selected) {
      // forward(from: 0) replays the ring — but only from TRUE rest. On a
      // bounce-back reselect the deselect reverse is mid-flight and the
      // glyph is still partially lit even at small values (the fade window's
      // curve puts value 0.1 at ~64% opacity), so restarting from 0 cut it
      // visibly. Any nonzero value continues instead; the ring simply
      // doesn't replay.
      if (_ctrl.value == 0) {
        _ctrl.forward(from: 0);
      } else {
        _ctrl.forward();
      }
    } else {
      // Deselection is quiet: settle back without replaying the ring.
      _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  static const _fadeWindow = Interval(0, 0.35, curve: MilesMotion.enter);
  static const _ringWindow = Interval(0.08, 1, curve: MilesMotion.heroEnter);

  @override
  Widget build(BuildContext context) {
    // off() is a live setting and this widget can be mid-bloom when it
    // flips: pin the controller to the finished end state so no ticker
    // survives the change. (didUpdateWidget alone missed this — it only
    // runs on a selection change.)
    if (MilesMotion.off(context) && _ctrl.isAnimating) {
      _ctrl.value = widget.selected ? 1 : 0;
    }
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _fadeWindow.transform(_ctrl.value);
        final ring = widget.selected ? _ringWindow.transform(_ctrl.value) : 0.0;
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            if (ring > 0 && ring < 1)
              IgnorePointer(
                child: Transform.scale(
                  scale: 0.8 + 0.7 * ring,
                  child: Opacity(
                    opacity: 0.5 * (1 - ring),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: MilesColors.gilt,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Transform.translate(
              offset: Offset(0, -2.0 * t),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Opacity(opacity: 1 - t, child: widget.icon),
                  Opacity(opacity: t, child: widget.selectedIcon),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
