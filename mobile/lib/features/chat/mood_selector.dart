import 'package:flutter/material.dart';
import 'package:miles/core/mood.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/animated_mood.dart';

/// A bottom sheet of mood chips. Returns the chosen [MoodData] (or null).
/// Scrollable so the full set (incl. the bold ones) is reachable on any screen.
Future<MoodData?> showMoodSelector(BuildContext context, {String? currentKey}) {
  return showModalBottomSheet<MoodData>(
    context: context,
    isScrollControlled: true,
    backgroundColor: MilesColors.surface1,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.72),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                      color: MilesColors.taupe,
                      borderRadius: BorderRadius.circular(2),),
                ),
              ),
              Text('How are you feeling?',
                  style: Theme.of(ctx).textTheme.titleLarge,),
              const SizedBox(height: 4),
              const Text('Your partner sees this with its glow.',
                  style: TextStyle(color: MilesColors.taupe, fontSize: 12.5),),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final m in kMoods)
                        GestureDetector(
                          onTap: () => Navigator.pop(ctx, m),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10,),
                            decoration: BoxDecoration(
                              color: m.color.withValues(
                                  alpha: currentKey == m.key ? 0.30 : 0.12,),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: m.color.withValues(
                                    alpha: currentKey == m.key ? 0.85 : 0.3,),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AnimatedMood(mood: m, size: 26),
                                const SizedBox(width: 6),
                                Text(m.label,
                                    style: const TextStyle(
                                        color: MilesColors.cream50,
                                        fontSize: 13,),),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
