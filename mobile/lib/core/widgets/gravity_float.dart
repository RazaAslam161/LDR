import 'package:flutter/material.dart';
import 'package:miles/core/ui/motion.dart';

/// GravityFloat — a hero element drifting ±3px on a slow sine, as if resting
/// on warm air (design-system.md §5).
///
/// HARD RULE: at most one per screen, and it IS that screen's ambient
/// element. Two things floating at different phases read as a broken layout,
/// and the motion contract's "one or two moving elements per view" counts
/// this as the one.
///
/// Transform-only, one controller, and under a covered route the ticker is
/// muted for free by route-scoped [TickerMode]. `off()` renders the resting
/// position with zero tickers.
class GravityFloat extends StatefulWidget {
  const GravityFloat({required this.child, this.by = 3.0, super.key});

  final Widget child;

  /// Drift amplitude in logical pixels. Small on purpose; past ~6px the
  /// element reads as unanchored rather than alive.
  final double by;

  @override
  State<GravityFloat> createState() => _GravityFloatState();
}

class _GravityFloatState extends State<GravityFloat>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: MilesMotion.float);
  late final Animation<Offset> _drift = Tween<Offset>(
    begin: Offset(0, -widget.by),
    end: Offset(0, widget.by),
  ).animate(CurvedAnimation(parent: _c, curve: MilesMotion.breathe));

  bool _running = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final off = MilesMotion.off(context);
    if (off && _running) {
      _c.stop();
      _c.value = 0.5; // resting center
      _running = false;
    } else if (!off && !_running) {
      _c.repeat(reverse: true);
      _running = true;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _drift,
      builder: (context, child) =>
          Transform.translate(offset: _drift.value, child: child),
      child: widget.child,
    );
  }
}
