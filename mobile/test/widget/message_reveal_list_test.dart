import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/message_reveal.dart';
import 'package:miles/features/chat/widgets/measured_row.dart';

/// The jump, driven against a REAL reversed ListView.builder.
///
/// message_reveal_test.dart proves the arithmetic. This proves the arithmetic
/// was about the right thing — same `reverse: true`, no itemExtent, wildly
/// uneven row heights, a GlobalKey on one row, and the same loop chat_screen
/// runs. The bug this file exists to prevent is the one the first design shipped
/// with: a jump that reports success on a row the list has already discarded.
/// So the assertion is never "the search said it found it" — it is always
/// "the row is on screen".
void main() {
  const rowCount = 200;

  // A photo grid beside a one-word bubble, which is what defeats a guess.
  double heightOf(int i) => i % 11 == 0 ? 380 : (i % 3 == 0 ? 56 : 104);
  String idOf(int i) => 'm$i';

  late ScrollController controller;
  late RowOffsets offsets;
  late GlobalKey revealKey;
  String? revealId;

  setUp(() {
    controller = ScrollController();
    offsets = RowOffsets();
    revealKey = GlobalKey();
    revealId = null;
  });

  tearDown(() => controller.dispose());

  Widget list(void Function(StateSetter)? setter) => MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setter?.call(setState);
              return ListView.builder(
                controller: controller,
                reverse: true,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                itemCount: rowCount,
                itemBuilder: (_, i) => MeasuredRow(
                  onHeight: (h) => offsets.record(idOf(i), h),
                  child: KeyedSubtree(
                    key: revealId == idOf(i) ? revealKey : null,
                    child: SizedBox(
                      height: heightOf(i),
                      child: Text('row $i'),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );

  /// The production loop, verbatim in shape.
  Future<bool> reveal(WidgetTester t, StateSetter setState, int index) async {
    setState(() => revealId = idOf(index));
    await t.pump();
    final ids = [for (var i = 0; i < rowCount; i++) idOf(i)];
    for (var pass = 0; pass < 4; pass++) {
      if (revealKey.currentContext != null) return true;
      final position = controller.position;
      final target = offsets.centredOffsetFor(
        ids,
        index,
        viewport: position.viewportDimension,
        maxExtent: position.maxScrollExtent,
      );
      final exactAlready = offsets.isExactFor(ids, index);
      controller.jumpTo(target);
      await t.pump();
      if (revealKey.currentContext != null) break;
      if (exactAlready) break;
    }
    // The same last step _landOn takes. Reaching the row is not the same as
    // showing it: a sliver keeps rows just outside the viewport alive in its
    // cache, so the key can resolve on a row that is built and still off
    // screen. ensureVisible is what closes that gap, and skipping it here
    // would let the test pass on a jump the user never sees land.
    final ctx = revealKey.currentContext;
    if (ctx == null) return false;
    await Scrollable.ensureVisible(ctx, alignment: 0.5);
    await t.pumpAndSettle();
    return true;
  }

  testWidgets('a row deep in the conversation lands on screen', (t) async {
    late StateSetter setState;
    await t.pumpWidget(list((s) => setState = s));
    await t.pumpAndSettle();

    expect(await reveal(t, setState, 150), isTrue);
    // The real assertion: the widget exists, not that a search said so.
    expect(find.text('row 150'), findsOneWidget);
  });

  testWidgets('every row is reachable, forwards and backwards', (t) async {
    late StateSetter setState;
    await t.pumpWidget(list((s) => setState = s));
    await t.pumpAndSettle();

    for (final target in [0, 1, 7, 42, 199, 143, 99, 3]) {
      expect(await reveal(t, setState, target), isTrue,
          reason: 'row $target was never reached',);
      expect(find.text('row $target'), findsOneWidget,
          reason: 'row $target was reported found but is not on screen',);
    }
  });

  testWidgets('the second pass is exact once the list has been walked',
      (t) async {
    late StateSetter setState;
    await t.pumpWidget(list((s) => setState = s));
    await t.pumpAndSettle();

    // One jump measures everything in front of the target, because a sliver
    // lays out in order. That is the property the whole design rests on.
    await reveal(t, setState, 180);
    final ids = [for (var i = 0; i < rowCount; i++) idOf(i)];
    expect(offsets.isExactFor(ids, 180), isTrue);
    expect(offsets.measuredCount, greaterThan(180));
  });
}
