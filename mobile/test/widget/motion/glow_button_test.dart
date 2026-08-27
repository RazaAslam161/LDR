import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/widgets/glow_button.dart';

/// The app's primary CTA used to re-rasterize its glow on every frame of
/// every press (blurRadius 22 → 36 through an AnimationController of its
/// own). The scale carries the press now, and these pin that: the button's
/// pixels are static, only its transform moves.
void main() {
  testWidgets('the decoration never changes across a press', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: GlowButton(label: 'Send', expand: false, onPressed: () {}),
        ),
      ),
    ));

    Decoration deco() => tester
        .widget<Container>(find.descendant(
          of: find.byType(GlowButton),
          matching: find.byType(Container),
        ))
        .decoration!;

    final atRest = deco();
    final gesture =
        await tester.startGesture(tester.getCenter(find.text('Send')));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(MilesMotion.instant);
    expect(identical(atRest, deco()), isTrue,
        reason: 'a press must not rebuild the gradient or the glow — the '
            'shadow is painted once and only moved');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('a disabled button neither scales nor calls back',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: GlowButton(
            label: 'Send',
            expand: false,
            loading: true, // disabled while loading
            onPressed: () => taps++,
          ),
        ),
      ),
    ));
    final gesture = await tester.startGesture(
        tester.getCenter(find.byType(GlowButton)),);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(MilesMotion.instant);
    final scales = tester
        .widgetList<Transform>(find.descendant(
          of: find.byType(GlowButton),
          matching: find.byType(Transform),
        ))
        .map((t) => t.transform.storage[0]);
    expect(scales.every((s) => s == 1.0), isTrue,
        reason: 'a control that cannot act must not answer a touch');
    await gesture.up();
    // NOT pumpAndSettle: a loading button holds a CircularProgressIndicator,
    // which by design never settles.
    await tester.pump(MilesMotion.quick);
    expect(taps, 0);
  });
}
