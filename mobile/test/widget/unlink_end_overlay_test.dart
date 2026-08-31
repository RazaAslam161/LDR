import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/features/unlink/scene/unlink_end_overlay.dart';

/// The overlay lives in main.dart's root Stack as a `Positioned.fill`, one
/// slot below WarmthOverlay. Build 68 shipped with SIX `_TypeError`s a launch
/// out of `Positioned.applyParentData` — the failure that greys the whole app
/// and swallows every touch, and which this file exists to make impossible to
/// ship again.
void main() {
  testWidgets('survives as a Positioned.fill directly inside a Stack',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Stack(
          children: [
            SizedBox.expand(),
            Positioned.fill(child: UnlinkEndOverlay()),
          ],
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('plays an ending without throwing', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Stack(
          children: [
            SizedBox.expand(),
            Positioned.fill(child: UnlinkEndOverlay()),
          ],
        ),
      ),
    );
    UnlinkEndOverlay.play.value = UnlinkEnding.relink;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('survives the REAL root chain: TickerMode > EmberBackground > Stack',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TickerMode(
          enabled: true,
          child: EmberBackground(
            child: Stack(
              children: const [
                SizedBox.expand(),
                Positioned.fill(child: UnlinkEndOverlay()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });
}
