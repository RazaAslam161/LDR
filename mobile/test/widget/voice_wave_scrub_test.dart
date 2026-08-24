import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/chat/widgets/voice_note_bubble.dart';

/// The waveform and the row's swipe-to-reply both want a horizontal drag.
///
/// This is the one part of the feature that reading the source cannot settle.
/// Both `Dismissible` and any drag recogniser on the waveform cross the touch
/// slop, and the gesture arena then resolves on pointer-event ordering — which
/// goes the way you want for a slow careful scrub and the way you do not for a
/// flick, where both cross in the SAME event. The fix under test is structural
/// rather than a bet: the waveform uses a raw Listener, which never enters the
/// arena, and while a finger is down the row's Dismissible is rebuilt with
/// `direction: none`, which installs no recogniser at all.
///
/// The third case is the one that matters most. Without it this file passes on
/// a build where scrubbing has quietly eaten reply-swipe for every voice note
/// in the conversation.
void main() {
  late List<Duration> seeks;
  late bool replied;
  late ValueNotifier<String?> scrubbing;

  setUp(() {
    seeks = [];
    replied = false;
    scrubbing = ValueNotifier<String?>(null);
  });

  tearDown(() => scrubbing.dispose());

  /// The real nesting from chat_screen.dart: a Dismissible whose direction is
  /// driven by the same notifier the bubble sets.
  Widget row({int? durationMs = 10000}) => MaterialApp(
        home: Scaffold(
          backgroundColor: MilesColors.night,
          body: Align(
            alignment: Alignment.topLeft,
            child: ValueListenableBuilder<String?>(
              valueListenable: scrubbing,
              builder: (context, current, _) => Dismissible(
                key: const ValueKey('rpl-m1'),
                direction: current == 'm1'
                    ? DismissDirection.none
                    : DismissDirection.startToEnd,
                dismissThresholds: const {
                  DismissDirection.startToEnd: 0.22,
                },
                confirmDismiss: (_) async {
                  replied = true;
                  return false;
                },
                child: VoiceNoteBubble(
                  url: 'https://example.invalid/v.m4a',
                  playing: false,
                  onToggle: () {},
                  senderName: 'them',
                  bubble: MilesColors.surface1,
                  durationMs: durationMs,
                  messageId: 'm1',
                  peaks: Uint8List.fromList(
                    List<int>.generate(56, (i) => 40 + i * 3),
                  ),
                  onSeek: seeks.add,
                  onScrub: ({required active}) =>
                      scrubbing.value = active ? 'm1' : null,
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('a slow scrub seeks and does not open a reply', (t) async {
    await t.pumpWidget(row());
    final wave = t.getCenter(find.byKey(waveKey));
    final g = await t.startGesture(wave);
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(6, 0));
      await t.pump();
    }
    await g.up();
    await t.pumpAndSettle();

    expect(seeks, isNotEmpty, reason: 'the drag never reached the player');
    expect(replied, isFalse, reason: 'swipe-to-reply stole the scrub');
  });

  testWidgets('a FLICK across the waveform still seeks, and does not reply',
      (t) async {
    // One large move: both recognisers would cross the slop in the same
    // pointer event, which is exactly the tie the arena resolves by traversal
    // order. This is the case that fails if the fix is "the inner one usually
    // wins".
    await t.pumpWidget(row());
    final wave = t.getCenter(find.byKey(waveKey));
    final g = await t.startGesture(wave);
    await g.moveBy(const Offset(80, 0));
    await t.pump();
    await g.up();
    await t.pumpAndSettle();

    expect(seeks, isNotEmpty);
    expect(replied, isFalse);
  });

  testWidgets('the same flick anywhere ELSE on the row still replies',
      (t) async {
    // The mirror. Without this, a build that disabled reply-swipe for the whole
    // voice row would pass every other test in this file.
    await t.pumpWidget(row());
    final play = t.getCenter(find.byIcon(Icons.play_arrow_rounded));
    final g = await t.startGesture(play);
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(20, 0));
      await t.pump();
    }
    await g.up();
    await t.pumpAndSettle();

    expect(replied, isTrue, reason: 'swipe-to-reply is gone from the row');
    expect(seeks, isEmpty);
  });

  testWidgets('a tap on the waveform seeks to where the finger landed',
      (t) async {
    await t.pumpWidget(row());
    final box = t.getRect(find.byKey(waveKey));
    // A quarter of the way along a ten-second note is about 2.5s.
    await t.tapAt(Offset(box.left + box.width * 0.25, box.center.dy));
    await t.pumpAndSettle();

    expect(seeks, hasLength(1));
    expect(seeks.single.inMilliseconds, closeTo(2500, 400));
  });

  testWidgets('a note whose length nobody knows cannot be scrubbed', (t) async {
    // Null duration is permanent for every note sent before the column existed.
    // There is no total to measure a fraction against, so the waveform draws
    // but does not pretend to be a control.
    await t.pumpWidget(row(durationMs: null));
    final wave = t.getCenter(find.byKey(waveKey));
    final g = await t.startGesture(wave);
    await g.moveBy(const Offset(60, 0));
    await t.pump();
    await g.up();
    await t.pumpAndSettle();

    expect(seeks, isEmpty);
  });
}
