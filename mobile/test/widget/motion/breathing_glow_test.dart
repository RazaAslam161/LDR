import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/widgets/breathing_glow.dart';

/// The rewrite's whole point, pinned: the glow is STATIC pixels that only
/// transform and fade. If someone reintroduces a per-frame decoration — an
/// animated shadow, a rebuilt gradient — these fail before the field does.
void main() {
  testWidgets('the glow decoration is identical across frames', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: BreathingGlow(
            child: SizedBox(width: 100, height: 100),
          ),
        ),
      ),
    ));

    Decoration deco() => tester
        .widget<DecoratedBox>(find.descendant(
          of: find.byType(BreathingGlow),
          matching: find.byType(DecoratedBox),
        ))
        .decoration;

    final first = deco();
    await tester.pump(const Duration(milliseconds: 700));
    final second = deco();
    expect(identical(first, second), isTrue,
        reason: 'the halo must be painted once and only moved — a decoration '
            'that changes per frame is the animated-shadow bug again');

    // And no shadow anywhere: the glow is a gradient now.
    expect((first as BoxDecoration).boxShadow, isNull);
  });

  testWidgets('animations off = mid-breath, zero tickers', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: const Center(
            child: BreathingGlow(child: SizedBox(width: 100, height: 100)),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0,
        reason: 'off() means the breath never starts');
    // The glow is still present — a finished state, not a stripped one.
    expect(
      find.descendant(
        of: find.byType(BreathingGlow),
        matching: find.byType(DecoratedBox),
      ),
      findsOneWidget,
    );
  });

  testWidgets('breathing runs when animations are on', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: BreathingGlow(child: SizedBox(width: 100, height: 100)),
        ),
      ),
    ));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0),
        reason: 'the breath is alive');
    // Never settles by design — advance a fixed slice instead.
    await tester.pump(const Duration(seconds: 2));
  });
}
