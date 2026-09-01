import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors the geometry of `_RoundBtn` in call_screen.dart: a fixed 60dp circle
/// with a label narrower than it.
///
/// A private widget cannot be pumped from here and CallController cannot be
/// built under test (its renderers need the platform plugin), so this guards the
/// arithmetic instead of the widget. Six controls at 60dp is 360dp — the exact
/// width of the most common phone — so the row that held five had no room for a
/// sixth, and screen share made it six. Keep this in step with that constant.
const double _btn = 60;

Widget _controls({required int count, required bool wrap}) => Directionality(
      textDirection: TextDirection.ltr,
      child: wrap
          ? Wrap(
              alignment: WrapAlignment.spaceEvenly,
              runSpacing: 16,
              children: List.generate(
                  count, (_) => const SizedBox(width: _btn, height: _btn),),
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(
                  count, (_) => const SizedBox(width: _btn, height: _btn),),
            ),
    );

Future<Object?> _pump(WidgetTester t, double width, Widget w) async {
  t.view.physicalSize = Size(width * 3, 800 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(w);
  return t.takeException();
}

void main() {
  // 320dp is a small handset; 360dp is the common one, and is also what a 411dp
  // phone becomes when its owner raises Android's display size.
  const widths = [320.0, 340.0, 360.0, 411.0];

  group('the call controls', () {
    testWidgets('do not overflow at any phone width', (t) async {
      for (final w in widths) {
        expect(await _pump(t, w, _controls(count: 6, wrap: true)), isNull,
            reason: 'six controls overflowed at ${w}dp',);
      }
    });

    // The reason the Wrap is there. If this ever stops failing, six buttons fit
    // in a plain Row and the comment in call_screen.dart is stale.
    testWidgets('would overflow as a plain Row, which is why they Wrap',
        (t) async {
      expect(await _pump(t, 320, _controls(count: 6, wrap: false)), isNotNull);
    });
  });
}
