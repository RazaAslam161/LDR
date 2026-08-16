import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/widgets/voice_note_bubble.dart';

/// Which voice note the play/pause icon is about.
///
/// One AudioPlayer serves the whole conversation, and every bubble used to
/// read `playing` straight off its shared stream. Start one note and the pause
/// icon appeared on all of them — the owner's words: "the play icon appears on
/// EVERY voice note in the chat rather than the one playing". Nothing about
/// that is visible with a single voice note on screen, which is why it shipped.
void main() {
  Widget two({required String? playingId}) => MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final id in ['a', 'b'])
                VoiceNoteBubble(
                  key: Key(id),
                  url: 'https://example.test/$id.m4a',
                  playing: id == playingId,
                  onToggle: () {},
                  senderName: 'your partner',
                  bubble: const Color(0xFF2A1B20),
                ),
            ],
          ),
        ),
      );

  testWidgets('only the note being heard shows a pause icon', (t) async {
    await t.pumpWidget(two(playingId: 'a'));

    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('a')),
            matching: find.byIcon(Icons.pause_rounded),),
        findsOneWidget,);
    expect(
        find.descendant(
            of: find.byKey(const Key('b')),
            matching: find.byIcon(Icons.play_arrow_rounded),),
        findsOneWidget,);
  });

  testWidgets('with nothing playing every note offers play', (t) async {
    await t.pumpWidget(two(playingId: null));

    expect(find.byIcon(Icons.play_arrow_rounded), findsNWidgets(2));
    expect(find.byIcon(Icons.pause_rounded), findsNothing);
  });

  /// How long a note runs, on the bubble, without playing it to find out.
  ///
  /// The bars are decoration — eighteen of them, height derived from the bar's
  /// index — so a two-second note and a two-minute note were drawn identically
  /// and the only way to learn the length was to listen to the whole thing.
  Widget one({
    int? durationMs,
    bool playing = false,
    Stream<Duration>? position,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: VoiceNoteBubble(
            url: 'https://example.test/a.m4a',
            playing: playing,
            onToggle: () {},
            senderName: 'your partner',
            bubble: const Color(0xFF2A1B20),
            durationMs: durationMs,
            positionStream: position,
          ),
        ),
      );

  testWidgets('a note says how long it runs', (t) async {
    await t.pumpWidget(one(durationMs: 7400));
    expect(find.text('0:07'), findsOneWidget);
  });

  testWidgets('past a minute it reads as minutes and seconds', (t) async {
    await t.pumpWidget(one(durationMs: 65000));
    expect(find.text('1:05'), findsOneWidget);
  });

  testWidgets('seconds round rather than truncate', (t) async {
    // 2.6s is nearer three seconds than two, and "2 seconds, 3 seconds" is
    // exactly the resolution this was reported at.
    await t.pumpWidget(one(durationMs: 2600));
    expect(find.text('0:03'), findsOneWidget);
  });

  testWidgets('a note held for an instant is a second, never 0:00', (t) async {
    // Rounding alone would floor this to 0:00, which beside a play button
    // reads as a recording that failed rather than a very short one.
    await t.pumpWidget(one(durationMs: 400));
    expect(find.text('0:01'), findsOneWidget);
    expect(find.text('0:00'), findsNothing);
  });

  testWidgets('a note from before the column shows no length, not a fake one',
      (t) async {
    // Every note sent so far, and everything from a client older than the
    // column — the fleet is sideloaded, so those keep arriving forever. An
    // unknown length is not zero, and it is not "--:--" either.
    await t.pumpWidget(one());
    expect(find.textContaining(':'), findsNothing);
  });

  testWidgets('an old note keeps exactly the layout it has today', (t) async {
    // The gap goes with the label. Dropping only the Text would leave an 8px
    // hole in the middle of every note already in the conversation.
    await t.pumpWidget(one());
    final without = t.widgetList<SizedBox>(find.byType(SizedBox)).length;
    await t.pumpWidget(one(durationMs: 3000));
    expect(t.widgetList<SizedBox>(find.byType(SizedBox)).length,
        without + 1,
        reason: 'the labelled note adds one gap, the bare one adds none',);
  });

  testWidgets('the playing note counts up from where it has got to',
      (t) async {
    final pos = StreamController<Duration>.broadcast();
    addTearDown(pos.close);
    await t.pumpWidget(
      one(durationMs: 30000, playing: true, position: pos.stream),
    );
    // Before any tick it reads zero rather than jumping to the total.
    expect(find.text('0:00'), findsOneWidget);

    pos.add(const Duration(seconds: 3));
    await t.pump();
    expect(find.text('0:03'), findsOneWidget);
    expect(find.text('0:30'), findsNothing);
  });

  testWidgets('a note with no stored length still counts while it plays',
      (t) async {
    // The player knows the real duration once it has loaded the audio, so the
    // twelve notes that predate the column are not mute about their length —
    // they just cannot say it until you press play.
    final pos = StreamController<Duration>.broadcast();
    addTearDown(pos.close);
    await t.pumpWidget(one(playing: true, position: pos.stream));
    pos.add(const Duration(seconds: 9));
    await t.pump();
    expect(find.text('0:09'), findsOneWidget);
  });

  testWidgets('an idle note shows its total, not the player position',
      (t) async {
    // Only the bubble that is playing may subscribe; a paused or idle note
    // reading the shared stream would show a position belonging to a
    // different note entirely.
    final pos = StreamController<Duration>.broadcast();
    addTearDown(pos.close);
    await t.pumpWidget(one(durationMs: 12000, position: pos.stream));
    pos.add(const Duration(seconds: 5));
    await t.pump();
    expect(find.text('0:12'), findsOneWidget);
    expect(find.text('0:05'), findsNothing);
  });

  test('the chat asks the player about THIS message, not about itself', () {
    // The widget above can only be as right as what the chat binds it to. A
    // `voice.playing` here instead of `voice.isPlaying(m.id)` reinstates the
    // bug with the bubble still passing its own tests.
    final chat =
        File('lib/features/chat/chat_screen.dart').readAsStringSync();
    expect(chat, contains('playing: voice.isPlaying(m.id)'));
    expect(chat, contains('onToggle: () => _play(context, voice, m.id, url)'));
  });
}
