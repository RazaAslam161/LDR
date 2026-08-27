import 'package:flutter/material.dart';
import 'package:miles/core/ui/motion.dart';

/// The tab-change dissolve for the shell. Tabs used to hard-swap —
/// `bodies[bodyIndex]` straight into the column, the only screens in the app
/// whose arrival had no motion at all.
///
/// SINGLE-CHILD by design, not an AnimatedSwitcher. The first version kept
/// the outgoing tab alive for the 220ms cross-fade, which meant two tab
/// bodies existed at once — and adversarial review proved that inverts the
/// Touch tab's FLAG_SECURE on a quick A-B-A bounce (the new instance sets
/// secure, the OLD one's delayed dispose then clears it, leaving screenshots
/// enabled on the intimate surface) and double-joins per-couple realtime
/// topics into the documented joined-but-dead state. Fading only the
/// INCOMING body keeps the original swap lifecycle — one instance, old
/// disposed in the same frame — and still gives the arrival its motion over
/// the shell's opaque night base.
///
/// Shape-stable across off() flips: the tree is always the same
/// FadeTransition, so a mid-session accessibility change re-times it instead
/// of remounting the whole tab (which destroyed in-progress state — an
/// AudioRecorder mid-note, most expensively).
class TabDissolve extends StatefulWidget {
  const TabDissolve({required this.index, required this.child, super.key});

  /// The shell's current tab. A change restarts the entrance fade.
  final int index;
  final Widget child;

  @override
  State<TabDissolve> createState() => _TabDissolveState();
}

class _TabDissolveState extends State<TabDissolve>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: MilesMotion.quick,
    value: 1,
  );

  @override
  void didUpdateWidget(TabDissolve old) {
    super.didUpdateWidget(old);
    if (widget.index == old.index) return;
    if (MilesMotion.off(context)) {
      _c.value = 1;
    } else {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      // drive(), not CurvedAnimation: build runs per tab switch and a
      // CurvedAnimation leaves a status listener on the controller forever.
      opacity: _c.drive(CurveTween(curve: MilesMotion.enter)),
      child: KeyedSubtree(
        key: ValueKey(widget.index),
        child: widget.child,
      ),
    );
  }
}
