import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/features/reach/reach_repository.dart';

/// Big hold-to-reach button. Hold ~0.5s (prevents accidental taps) to send a
/// Reach; 30-second cooldown afterwards (shown as the label).
class ReachButton extends StatefulWidget {
  const ReachButton({required this.coupleId, super.key, this.partnerName});
  final String coupleId;
  final String? partnerName;

  @override
  State<ReachButton> createState() => _ReachButtonState();
}

class _ReachButtonState extends State<ReachButton> {
  DateTime? _cooldownUntil;
  Timer? _ticker;
  bool _sending = false;

  bool get _onCooldown =>
      _cooldownUntil != null && _cooldownUntil!.isAfter(DateTime.now());
  int get _remaining => _cooldownUntil == null
      ? 0
      : _cooldownUntil!.difference(DateTime.now()).inSeconds.clamp(0, 30);

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _reach() async {
    if (_onCooldown || _sending) return;
    setState(() => _sending = true);
    HapticFeedback.mediumImpact();
    try {
      await ReachRepository.reach(widget.coupleId);
      _cooldownUntil = DateTime.now().add(const Duration(seconds: 30));
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
        if (!_onCooldown) _ticker?.cancel();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text('Reaching for ${widget.partnerName ?? 'them'}… 💕'),),);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not reach right now.')),);
      }
    }
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final disabled = _onCooldown || _sending;
    return Column(
      children: [
        GestureDetector(
          onLongPress: _reach,
          child: AnimatedScale(
            scale: disabled ? 0.94 : 1,
            duration: const Duration(milliseconds: 200),
            child: Container(
              width: 132,
              height: 132,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: MilesGradients.cta,
                boxShadow: [
                  BoxShadow(
                    color: MilesColors.blush.withValues(alpha: disabled ? 0.15 : 0.45),
                    blurRadius: 36,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Center(
                child: _sending
                    ? const CircularProgressIndicator(
                        color: MilesColors.cream50,)
                    : const Icon(Icons.front_hand_outlined,
                        color: MilesColors.cream50, size: 52,),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          _onCooldown ? 'Wait ${_remaining}s' : 'Hold to reach',
          style: const TextStyle(color: MilesColors.taupe, fontSize: 13),
        ),
      ],
    );
  }
}
