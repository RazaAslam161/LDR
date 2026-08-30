import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/chat/widgets/voice_note_bubble.dart';

/// The speed chip belongs to playback, not to a message.
///
/// Reported from a handset with three voice notes on screen: tapping 1.5x on
/// one of them changed the number on all three. The rate was never per-note —
/// it is one remembered setting, which is what was asked for — but a chip drawn
/// on every bubble made a shared control look private, so one tap appeared to
/// rewrite messages the user had not touched.
///
/// The fix is not to make speed per-note; that would mean setting it again on
/// every single note, which is the annoyance the feature exists to remove. It
/// is to stop drawing the control on notes it is not about.
void main() {
  Widget two({String? currentId, double speed = 1.0}) => MaterialApp(
        home: Scaffold(
          backgroundColor: MilesColors.night,
          body: Column(
            children: [
              for (final id in ['a', 'b'])
                VoiceNoteBubble(
                  url: 'https://example.invalid/$id.m4a',
                  playing: false,
                  onToggle: () {},
                  senderName: 'them',
                  bubble: MilesColors.surface1,
                  durationMs: 8000,
                  messageId: id,
                  speed: speed,
                  current: currentId == id,
                  onCycleSpeed: () {},
                ),
            ],
          ),
        ),
      );

  testWidgets('with nothing loaded, no bubble offers a speed chip',
      (t) async {
    await t.pumpWidget(two());
    expect(find.text('1x'), findsNothing);
  });

  testWidgets('exactly one chip appears, on the note the player holds',
      (t) async {
    // The regression. Before the fix this found two, and tapping either one
    // moved the number on both.
    await t.pumpWidget(two(currentId: 'b', speed: 1.5));
    expect(find.text('1.5x'), findsOneWidget);
  });

  testWidgets('the chip follows the player when a different note is loaded',
      (t) async {
    await t.pumpWidget(two(currentId: 'a', speed: 2));
    expect(find.text('2x'), findsOneWidget);
    await t.pumpWidget(two(currentId: 'b', speed: 2));
    expect(find.text('2x'), findsOneWidget);
  });

  testWidgets('tapping the chip asks for the next rate', (t) async {
    var cycled = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VoiceNoteBubble(
            url: 'https://example.invalid/a.m4a',
            playing: true,
            onToggle: () {},
            senderName: 'them',
            bubble: MilesColors.surface1,
            durationMs: 8000,
            messageId: 'a',
            current: true,
            speed: 1.5,
            onCycleSpeed: () => cycled++,
          ),
        ),
      ),
    );
    await t.tap(find.text('1.5x'));
    await t.pump();
    expect(cycled, 1);
  });

  testWidgets('the chip adds no clock to a note that has no length', (t) async {
    // voice_note_bubble_test asserts an unlabelled note draws no text
    // containing ':' — null duration is permanent for everything sent before
    // the column existed. The chip shares that row, so its label must stay
    // clear of that shape at every rate.
    for (final s in [1.0, 1.5, 2.0]) {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoiceNoteBubble(
              url: 'https://example.invalid/a.m4a',
              playing: false,
              onToggle: () {},
              senderName: 'them',
              bubble: MilesColors.surface1,
              messageId: 'a',
              current: true,
              speed: s,
              onCycleSpeed: () {},
            ),
          ),
        ),
      );
      expect(find.textContaining(':'), findsNothing, reason: 'rate $s');
    }
  });
}
