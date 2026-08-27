import 'dart:async';
import 'package:flutter/material.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/breathing_glow.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/features/reach/reach_repository.dart';
import 'package:miles/features/reach/widgets/reach_pulse.dart';
import 'package:vibration/vibration.dart';

/// Full-screen "[partner] is reaching for you 💕" alert, shown when a reach
/// lands while the app is in the foreground.
///
/// NOTE: waking the screen when the app is backgrounded/closed needs FCM with a
/// full-screen-intent notification — see `lib/core/push/fcm_todo.dart`. The
/// manifest already declares USE_FULL_SCREEN_INTENT + WAKE_LOCK for that.
class ReachOverlayScreen extends StatefulWidget {
  const ReachOverlayScreen({
    required this.partnerName, required this.eventId, super.key,
  });

  final String partnerName;
  final String eventId;

  @override
  State<ReachOverlayScreen> createState() => _ReachOverlayScreenState();
}

class _ReachOverlayScreenState extends State<ReachOverlayScreen> {
  @override
  void initState() {
    super.initState();
    _buzz();
  }

  Future<void> _buzz() async {
    try {
      if (await Vibration.hasVibrator()) {
        unawaited(Vibration.vibrate(pattern: const [0, 300, 120, 500, 120, 300]));
      }
    } catch (_) {}
  }

  Future<void> _acknowledge() async {
    try {
      await ReachRepository.acknowledge(widget.eventId);
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: EmberBackground(
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // The receiver's heart carries the sender's heartbeat — the
                // same ReachPulse lub-dub, over the breathing glow.
                const BreathingGlow(
                  period: Duration(milliseconds: 1700),
                  child: ReachPulse(
                    child: Text('💗', style: TextStyle(fontSize: 96)),
                  ),
                ),
                const SizedBox(height: 32),
                EntranceStagger(
                  children: [
                    Text('${widget.partnerName} is',
                        style: const TextStyle(
                            color: MilesColors.taupe, fontSize: 16,),),
                    Text('reaching for you 💕',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.displaySmall,),
                  ],
                ),
                const SizedBox(height: 48),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: MilesColors.blush,),
                      onPressed: _acknowledge,
                      child: const Text("I'm here 💕"),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Dismiss',
                      style: TextStyle(color: MilesColors.faint),),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
