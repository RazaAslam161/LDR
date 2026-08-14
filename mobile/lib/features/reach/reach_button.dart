import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/reach/reach_repository.dart';

/// Big hold-to-reach button. Hold ~0.5s (prevents accidental taps) to send a
/// Reach; the wait afterwards belongs to the server and is read back from it.
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
      : _cooldownUntil!.difference(DateTime.now()).inSeconds;

  @override
  void initState() {
    super.initState();
    unawaited(_syncCooldown());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Ask the server how long the wait is, instead of remembering it here.
  ///
  /// The countdown used to live only in this State: it was cleared by an app
  /// restart, so the button came back ready every time Home was rebuilt, and
  /// it never applied at all to anything talking to PostgREST directly. The
  /// trigger decides now, and this is how the button finds out before the
  /// person is told no.
  Future<void> _syncCooldown() async {
    final int seconds;
    try {
      seconds = await ReachRepository.cooldownSeconds();
    } catch (_) {
      return; // Leave the label as it was; the trigger still refuses the send.
    }
    if (!mounted) return;
    setState(() => _cooldownUntil =
        seconds > 0 ? DateTime.now().add(Duration(seconds: seconds)) : null,);
    _ticker?.cancel();
    if (seconds == 0) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {});
      if (!_onCooldown) t.cancel();
    });
  }

  Future<void> _reach() async {
    if (_onCooldown || _sending) return;
    setState(() => _sending = true);
    unawaited(HapticFeedback.mediumImpact());
    var sent = true;
    try {
      await ReachRepository.reach(widget.coupleId);
    } catch (_) {
      sent = false;
    }
    await _syncCooldown();
    if (!mounted) return;
    setState(() => _sending = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          sent
              ? 'Reaching for ${widget.partnerName ?? 'them'}… 💕'
              // A refused send and a dead network are different apologies, and
              // the cooldown the server just handed back tells them apart.
              : _onCooldown
                  ? 'That was a lot at once — try again in ${_wait()}.'
                  : 'Could not reach right now.',
        ),
      ),
    );
  }

  /// The window limit runs to minutes, so the old "${n}s" would have counted
  /// down from 300.
  String _wait() =>
      _remaining >= 60 ? '${(_remaining / 60).ceil()} min' : '${_remaining}s';

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
          _onCooldown ? 'Wait ${_wait()}' : 'Hold to reach',
          style: const TextStyle(color: MilesColors.taupe, fontSize: 13),
        ),
      ],
    );
  }
}
