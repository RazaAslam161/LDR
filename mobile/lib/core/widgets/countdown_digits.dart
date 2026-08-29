import 'dart:async';

import 'package:flutter/material.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/ui/theme.dart';

/// CountTick — a countdown whose digits turn like a quiet flip clock
/// (design-system.md §5): each character that changes cross-fades with a 2px
/// downward slip over [MilesMotion.tick]; unchanged characters hold still.
///
/// Far out it reads coarsely ('12 days', '9 hrs') and ticks once a minute;
/// inside the final hour it becomes a live mm:ss. Tabular figures keep the
/// columns from wobbling as digits change. With animations off the digits
/// still UPDATE — a clock must tell the time — they just stop performing the
/// turn.
class CountdownDigits extends StatefulWidget {
  const CountdownDigits({
    required this.until,
    this.style,
    this.clock,
    super.key,
  });

  final DateTime until;
  final TextStyle? style;

  /// The clock [until] is measured against. Defaults to the handset's, which
  /// is right for a deadline the handset itself set. A deadline computed by
  /// Postgres must pass `ServerClock.now` instead — a phone an hour fast
  /// otherwise counts a ceremony down an hour early.
  final DateTime Function()? clock;

  @override
  State<CountdownDigits> createState() => _CountdownDigitsState();
}

class _CountdownDigitsState extends State<CountdownDigits> {
  Timer? _timer;
  late String _text = _format();

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(CountdownDigits old) {
    super.didUpdateWidget(old);
    if (old.until != widget.until) {
      _text = _format();
      _arm();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Duration get _left {
    final d = widget.until.difference(widget.clock?.call() ?? DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  String _format() {
    final left = _left;
    if (left == Duration.zero) return 'now';
    if (left.inHours >= 48) return '${left.inDays} days';
    if (left.inHours >= 1) {
      final h = left.inHours;
      final m = left.inMinutes % 60;
      return '$h h ${m.toString().padLeft(2, '0')} m';
    }
    final m = left.inMinutes;
    final s = left.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _arm() {
    _timer?.cancel();
    final fast = _left.inHours < 1;
    _timer = Timer.periodic(
      fast ? const Duration(seconds: 1) : const Duration(minutes: 1),
      (_) {
        final next = _format();
        final cadenceFlip = (_left.inHours < 1) != fast;
        if (next != _text && mounted) setState(() => _text = next);
        if (cadenceFlip) _arm();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final off = MilesMotion.off(context);
    final style = (widget.style ??
            Theme.of(context).textTheme.headlineMedium ??
            const TextStyle())
        .copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
      color: MilesColors.starlight,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _text.length; i++)
          AnimatedSwitcher(
            duration: off ? Duration.zero : MilesMotion.tick,
            switchInCurve: MilesMotion.enter,
            switchOutCurve: MilesMotion.enter,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: AnimatedBuilder(
                animation: anim,
                builder: (context, inner) => Transform.translate(
                  offset: Offset(0, 2 * (1 - anim.value)),
                  child: inner,
                ),
                child: child,
              ),
            ),
            child: Text(
              _text[i],
              key: ValueKey('$i-${_text[i]}'),
              style: style,
            ),
          ),
      ],
    );
  }
}
