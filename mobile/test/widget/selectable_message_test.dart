import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/widgets/selectable_message.dart';

/// Wrapping a bubble in a GestureDetector and calling it done is wrong, and
/// wrong in a way that source-reading review does not catch: the media bubbles
/// have their own tap handlers, those recognizers sit deeper in the tree, and
/// the innermost one wins the arena. The outer onTap fires on text and on
/// nothing else — so selecting ten photos still costs ten long-presses, which
/// is the exact cost the feature was meant to remove.
///
/// These pump the real widget with the real nesting.
void main() {
  /// A stand-in for a photo bubble: something with its own onTap, like
  /// MediaViewer.open or the voice player's play button.
  ///
  /// The child paints. A bare SizedBox has nothing to hit-test against, so a
  /// tap lands on neither handler and every assertion here passes vacuously.
  Widget build({
    required bool selecting,
    required VoidCallback onToggle,
    required VoidCallback onInner,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SelectableMessage(
              selecting: selecting,
              selected: false,
              onToggle: onToggle,
              child: GestureDetector(
                onTap: onInner,
                child: Container(
                    width: 200, height: 200, color: const Color(0xFF333333),),
              ),
            ),
          ),
        ),
      );

  testWidgets('with no selection open, a tap still opens the media', (t) async {
    final fired = <String>[];
    await t.pumpWidget(build(
      selecting: false,
      onToggle: () => fired.add('toggle'),
      onInner: () => fired.add('open'),
    ),);

    await t.tapAt(t.getCenter(find.byType(SelectableMessage)));
    await t.pump();

    expect(fired, ['open'], reason: 'tapping a photo normally opens it');
  });

  testWidgets('once selecting, a tap picks the media instead of opening it',
      (t) async {
    // The regression: without taking the child out of the hit test, the inner
    // recognizer wins and this fires 'open' — the photo goes full screen and
    // is never added to the selection.
    final fired = <String>[];
    await t.pumpWidget(build(
      selecting: true,
      onToggle: () => fired.add('toggle'),
      onInner: () => fired.add('open'),
    ),);

    await t.tapAt(t.getCenter(find.byType(SelectableMessage)));
    await t.pump();

    expect(fired, ['toggle'],
        reason: 'a tap during selection must pick, and must not open',);
  });

  testWidgets('long-press starts a selection from a media bubble', (t) async {
    final fired = <String>[];
    await t.pumpWidget(build(
      selecting: false,
      onToggle: () => fired.add('toggle'),
      onInner: () => fired.add('open'),
    ),);

    await t.longPressAt(t.getCenter(find.byType(SelectableMessage)));
    await t.pump();

    expect(fired, ['toggle']);
  });

  testWidgets('a selected bubble is visibly distinct', (t) async {
    // Without this the count in the bar is the only feedback, and the user
    // cannot tell which of two adjacent photos they actually picked.
    Color colorOf(WidgetTester t) => t
        .widgetList<ColoredBox>(find.descendant(
          of: find.byType(SelectableMessage),
          matching: find.byType(ColoredBox),
        ),)
        .first
        .color;

    await t.pumpWidget(MaterialApp(
      home: SelectableMessage(
        selecting: true,
        selected: false,
        onToggle: () {},
        child: Container(width: 10, height: 10, color: const Color(0xFF222222)),
      ),
    ),);
    final unselected = colorOf(t);

    await t.pumpWidget(MaterialApp(
      home: SelectableMessage(
        selecting: true,
        selected: true,
        onToggle: () {},
        child: Container(width: 10, height: 10, color: const Color(0xFF222222)),
      ),
    ),);

    expect(colorOf(t), isNot(unselected));
    expect(unselected.a, 0, reason: 'an unselected bubble must not be tinted');
  });
}
