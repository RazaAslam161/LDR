import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/ui/theme.dart';

/// ReachPulse — the Reach gesture's heartbeat (design-system.md §5).
///
/// A lub-dub, not a sine: the child scales through a two-peak sequence each
/// [MilesMotion.beat], and a thin ring ripples outward once per beat (a
/// static circle border moved by scale and killed by fade — no animated
/// decoration). [bloomTick] plays the one-shot release bloom — a larger,
/// slower ring at [MilesMotion.reveal] — whenever its value changes; the
/// sender pings it on a successful send.
///
/// Transform and opacity only. With animations off nothing beats: the child
/// renders at rest and blooms are skipped — the haptic already carries the
/// moment for a user who asked motion to stop.
class ReachPulse extends StatefulWidget {
  const ReachPulse({
    required this.child,
    this.beating = true,
    this.color = MilesColors.blush,
    this.bloomTick,
    super.key,
  });

  final Widget child;

  /// Whether the resting heartbeat runs. The sender stops beating on
  /// cooldown — a button that cannot be pressed must not keep inviting.
  final bool beating;

  final Color color;

  /// Bump to play the release bloom once.
  final ValueListenable<int>? bloomTick;

  @override
  State<ReachPulse> createState() => _ReachPulseState();
}

class _ReachPulseState extends State<ReachPulse>
    with TickerProviderStateMixin {
  late final AnimationController _beat =
      AnimationController(vsync: this, duration: MilesMotion.beat);
  late final AnimationController _bloom =
      AnimationController(vsync: this, duration: MilesMotion.reveal);

  /// The lub-dub: two peaks, the second softer, then rest.
  static final Animatable<double> _lubDub = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1, end: 1.12), weight: 18),
    TweenSequenceItem(tween: Tween(begin: 1.12, end: 1.02), weight: 16),
    TweenSequenceItem(tween: Tween(begin: 1.02, end: 1.08), weight: 16),
    TweenSequenceItem(tween: Tween(begin: 1.08, end: 1), weight: 25),
    TweenSequenceItem(tween: ConstantTween(1), weight: 25),
  ]);

  bool _running = false;

  @override
  void initState() {
    super.initState();
    widget.bloomTick?.addListener(_onBloom);
  }

  void _onBloom() {
    if (!MilesMotion.off(context)) _bloom.forward(from: 0);
  }

  void _sync() {
    final should = widget.beating && !MilesMotion.off(context);
    if (should && !_running) {
      _beat.repeat();
      _running = true;
    } else if (!should && _running) {
      _beat.stop();
      _beat.value = 0;
      _running = false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ReachPulse old) {
    super.didUpdateWidget(old);
    if (old.bloomTick != widget.bloomTick) {
      old.bloomTick?.removeListener(_onBloom);
      widget.bloomTick?.addListener(_onBloom);
    }
    _sync();
  }

  @override
  void dispose() {
    widget.bloomTick?.removeListener(_onBloom);
    _beat.dispose();
    _bloom.dispose();
    super.dispose();
  }

  Widget _ring(Animation<double> t, {required double reach, required double width}) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: t,
        builder: (context, _) {
          final v = t.value;
          if (v == 0 || v == 1) return const SizedBox.shrink();
          return Transform.scale(
            scale: 1.0 + reach * v,
            child: Opacity(
              opacity: 0.5 * (1 - v),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: widget.color, width: width),
                ),
                child: const SizedBox.expand(),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ripple = _beat.drive(CurveTween(curve: MilesMotion.breathe));
    final bloom = _bloom.drive(CurveTween(curve: MilesMotion.heroEnter));
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: _ring(ripple, reach: 0.6, width: 1.5)),
        Positioned.fill(child: _ring(bloom, reach: 1.2, width: 2.5)),
        AnimatedBuilder(
          animation: _beat,
          builder: (context, child) => Transform.scale(
            scale: _lubDub.transform(_beat.value),
            child: child,
          ),
          child: widget.child,
        ),
      ],
    );
  }
}
