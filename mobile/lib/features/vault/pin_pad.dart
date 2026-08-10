import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/theme.dart';

/// A 4-digit PIN pad: filled dots + number grid + backspace. Calls [onComplete]
/// once 4 digits are entered. Bump [errorSignal] from the parent to shake +
/// clear (e.g. on a wrong PIN).
class PinPad extends StatefulWidget {
  const PinPad({
    required this.onComplete, super.key,
    this.errorSignal = 0,
    this.enabled = true,
  });

  final ValueChanged<String> onComplete;
  final int errorSignal;
  final bool enabled;

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad>
    with SingleTickerProviderStateMixin {
  String _pin = '';
  late final AnimationController _shake =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 450));

  @override
  void didUpdateWidget(PinPad old) {
    super.didUpdateWidget(old);
    if (old.errorSignal != widget.errorSignal) {
      setState(() => _pin = '');
      _shake.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  void _add(String d) {
    if (!widget.enabled || _pin.length >= 4) return;
    HapticFeedback.selectionClick();
    setState(() => _pin += d);
    if (_pin.length == 4) widget.onComplete(_pin);
  }

  void _back() {
    if (_pin.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _shake,
          builder: (context, child) {
            final dx = math.sin(_shake.value * math.pi * 4) * 10 * (1 - _shake.value);
            return Transform.translate(offset: Offset(dx, 0), child: child);
          },
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(4, (i) {
              final filled = i < _pin.length;
              return Container(
                width: 16,
                height: 16,
                margin: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: filled ? MilesColors.blush : Colors.transparent,
                  border: Border.all(
                    color: filled
                        ? MilesColors.blush
                        : MilesColors.gilt.withValues(alpha: 0.4),
                    width: 1.5,
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 40),
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [for (final d in row) _key(d)],
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(width: 76),
            _key('0'),
            _IconKey(icon: Icons.backspace_outlined, onTap: _back),
          ],
        ),
      ],
    );
  }

  Widget _key(String d) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: GestureDetector(
        onTap: () => _add(d),
        child: Container(
          width: 60,
          height: 60,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: MilesColors.surface1,
            border: Border.all(color: MilesColors.gilt.withValues(alpha: 0.12)),
          ),
          child: Text(d,
              style: const TextStyle(
                  color: MilesColors.cream50,
                  fontSize: 24,
                  fontWeight: FontWeight.w300,),),
        ),
      ),
    );
  }
}

class _IconKey extends StatelessWidget {
  const _IconKey({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 60,
          height: 60,
          child: Icon(icon, color: MilesColors.taupe),
        ),
      ),
    );
  }
}
