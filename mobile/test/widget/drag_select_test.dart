import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/widgets/drag_select.dart';

/// Press-and-slide selection, which the gallery, the vault and the chat all
/// drive through one widget.
///
/// The two things worth pinning are the two that a hand-rolled version gets
/// wrong: a plain drag must still SCROLL (or a selecting user can never reach
/// anything off-screen), and the span must be re-derived rather than toggled
/// per cell crossed (or sliding back over a tile selects it a second time
/// instead of releasing it).
void main() {
  group('dragSelectSpan', () {
    test('runs low to high whichever way the finger went', () {
      expect(dragSelectSpan(2, 5).toList(), [2, 3, 4, 5]);
      expect(dragSelectSpan(5, 2).toList(), [2, 3, 4, 5]);
    });

    test('an anchor with no movement is one item, not none', () {
      expect(dragSelectSpan(3, 3).toList(), [3]);
    });
  });

  group('DragSelect', () {
    late List<int> anchors;
    late List<List<int>> extents;
    late int ends;
    late ScrollController scroll;

    Widget harness() {
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 400,
            width: 300,
            child: DragSelect(
              scroll: scroll,
              onAnchor: anchors.add,
              onExtend: (a, e) => extents.add([a, e]),
              onEnd: () => ends++,
              child: GridView.builder(
                controller: scroll,
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                ),
                itemCount: 30,
                itemBuilder: (_, i) => DragSelectItem(
                  index: i,
                  child: ColoredBox(
                    color: Colors.blue,
                    child: Center(child: Text('$i')),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    setUp(() {
      anchors = [];
      extents = [];
      ends = 0;
      scroll = ScrollController();
    });

    tearDown(() => scroll.dispose());

    testWidgets('a long press anchors on the cell under the finger',
        (tester) async {
      await tester.pumpWidget(harness());
      final gesture =
          await tester.startGesture(tester.getCenter(find.text('4')),
              pointer: 11,);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pump();

      expect(anchors, [4]);
      expect(ends, 1);
    });

    testWidgets('sliding reports the whole span, not each cell crossed',
        (tester) async {
      await tester.pumpWidget(harness());
      final gesture =
          await tester.startGesture(tester.getCenter(find.text('1')),
              pointer: 12,);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveTo(tester.getCenter(find.text('2')));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.text('5')));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(anchors, [1]);
      // Every update carries the anchor AND the current extent, so the caller
      // can rebuild the whole selection from its snapshot each time.
      expect(extents, [
        [1, 2],
        [1, 5],
      ]);
    });

    testWidgets('sliding BACK reports the shrunken span, so a cell releases',
        (tester) async {
      await tester.pumpWidget(harness());
      final gesture =
          await tester.startGesture(tester.getCenter(find.text('0')),
              pointer: 13,);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveTo(tester.getCenter(find.text('5')));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.text('2')));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(extents.last, [0, 2]);
    });

    testWidgets('a plain drag still scrolls and selects nothing',
        (tester) async {
      await tester.pumpWidget(harness());
      // No dwell: the Scrollable's drag claims the pointer at kTouchSlop long
      // before the long-press timer would fire. This is the case that would
      // make drag-select unusable if it were taken by the wrong recognizer.
      await tester.drag(find.byType(GridView), const Offset(0, -240));
      await tester.pumpAndSettle();

      expect(anchors, isEmpty);
      expect(extents, isEmpty);
      expect(scroll.offset, greaterThan(0));
    });

    testWidgets('enabled: false leaves the gesture entirely alone',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DragSelect(
              enabled: false,
              onAnchor: anchors.add,
              onExtend: (a, e) => extents.add([a, e]),
              onEnd: () => ends++,
              child: const DragSelectItem(
                index: 0,
                // A painted child, so the finder has a real hit target and the
                // test is about the recognizer rather than about hit testing.
                child: SizedBox(
                  width: 100,
                  height: 100,
                  child: ColoredBox(color: Colors.blue),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.longPress(find.byType(ColoredBox).first);
      await tester.pump();

      expect(anchors, isEmpty);
    });
  });
}
