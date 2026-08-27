import 'package:flutter/material.dart';
import 'package:miles/core/ui/motion.dart';

/// The three-line way a screen adopts the house entrance: its content rises
/// and fades in as one coordinated sequence, on the same [EntranceStagger]
/// the auth flow proved. This exists so choreography is a wrapper, not a
/// memory — a screen that forgets it simply doesn't move, and the rollout
/// finds it by eye.
///
/// The route-level DissolveIn already gives every pushed screen its arrival
/// as one unit; this is the UPGRADE for screens whose content deserves
/// sequenced composition (a column of cards, a settings list's sections).
/// Per the motion contract it IS the screen's entrance system — one moving
/// system, however many children ride it.
class ScreenEntrance extends StatelessWidget {
  const ScreenEntrance({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => EntranceStagger(children: children);
}
