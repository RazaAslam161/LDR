import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/unlink/scene/conversation.dart';
import 'package:miles/features/unlink/scene/doorstep_scene.dart';

/// The phone's scene-side contract.
///
/// The old law here was "their text renders BELOW the script" — a chronology
/// law, correct while the talk was a chat log stacked at the bottom of the
/// screen. The talk is no longer a log: every line hangs off the head of
/// whoever said it, so position now means WHO, not WHEN. The law that
/// survives is the one that always mattered: a real person's words appear,
/// they appear on the character's side of the stage rather than the
/// companion's, and an absent message renders nothing at all.
void main() {
  const canvas = Size(360, 700);

  // The default bench is 800x600, which squashes a 700-tall host and turns
  // every anchored position into a lie. The stage is a phone; size the bench
  // like one.
  Future<void> phoneBench(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(canvas);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Widget host({String? phoneLine, List<Exchange> lines = const []}) =>
      MaterialApp(
        home: ColoredBox(
          color: const Color(0xFF120A0C),
          child: SizedBox(
            width: canvas.width,
            height: canvas.height,
            child: conversationStackForTest(
              lines: lines,
              lateLine: null,
              outside: false,
              phoneLine: phoneLine,
            ),
          ),
        ),
      );

  testWidgets('their text stands on the character, not the companion',
      (tester) async {
    await phoneBench(tester);
    await tester.pumpWidget(
      host(
        phoneLine: 'come back inside, please',
        lines: const [
          Exchange(0.5, Speaker.companion, 'The whole street heard.'),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('come back inside, please'), findsOneWidget);
    expect(find.text('The whole street heard.'), findsOneWidget);

    // The seam puts the companion's head at y=210 and the character's at
    // y=364. Each line must land nearer the head that said it — that IS the
    // layout, and it is what makes the stage read as two people talking
    // rather than one feed scrolling.
    const companionHeadY = 0.30 * 700;
    const characterHeadY = 0.52 * 700;
    final phoneY = tester.getCenter(find.text('come back inside, please')).dy;
    final scriptY = tester.getCenter(find.text('The whole street heard.')).dy;
    expect((phoneY - characterHeadY).abs(),
        lessThan((phoneY - companionHeadY).abs()),
        reason: 'a message from a real person belongs at the character '
            'holding the phone, not at the bird',);
    expect((scriptY - companionHeadY).abs(),
        lessThan((scriptY - characterHeadY).abs()),
        reason: "the companion's line belongs at the companion",);
  });

  testWidgets('words keep out from under the clock plate', (tester) async {
    // The plate paints AFTER the stage, so without this it simply covers
    // whoever is speaking: the owner's handset showed the cat's line cut off
    // mid-word behind it ("Because I'm the one who go|"). The talk narrows
    // rather than moving — a bubble slid out from under its own speaker is a
    // worse lie than a short one.
    await phoneBench(tester);
    const plate = Rect.fromLTWH(232, 0, 128, 150);
    await tester.pumpWidget(
      MaterialApp(
        home: ColoredBox(
          color: const Color(0xFF120A0C),
          child: SizedBox(
            width: canvas.width,
            height: canvas.height,
            child: conversationStackForTest(
              lines: const [
                // The companion's head sits at y=210 in the seam, so this
                // line lands squarely in the plate's band.
                Exchange(0.5, Speaker.companion, 'Because I am the one who '
                    'got left, and the whole street heard it.'),
              ],
              lateLine: null,
              outside: false,
              canvas: canvas,
              avoid: plate,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final box = tester.getRect(
      find.textContaining('Because I am the one'),
    );
    expect(box.right, lessThanOrEqualTo(plate.left),
        reason: 'the words run under the plate: right=${box.right} vs '
            'plate.left=${plate.left}',);
    expect(box.width, greaterThan(100),
        reason: 'narrowed past the point of being a sentence',);
  });

  testWidgets('no message renders no bubble at all', (tester) async {
    await phoneBench(tester);
    await tester.pumpWidget(host());
    await tester.pump();
    expect(find.byType(Container), findsNothing,
        reason: 'an empty stage must collapse, not frame nothing',);
  });

  testWidgets('someone about to speak shows dots at their own side',
      (tester) async {
    await phoneBench(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: ColoredBox(
          color: const Color(0xFF120A0C),
          child: SizedBox(
            width: canvas.width,
            height: canvas.height,
            child: conversationStackForTest(
              lines: const [],
              lateLine: null,
              outside: true,
              pending: Speaker.companion,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // Three dots and nothing else: the silence before a line is inhabited,
    // which is the whole difference between a pause and a stalled screen.
    expect(find.byType(Text), findsNothing);
    expect(find.byType(Container), findsWidgets);
  });
}
