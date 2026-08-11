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
