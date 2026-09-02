
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/features/disguise/cover_gate.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:miles/features/disguise/entry/cover_entry_scope.dart';
import 'package:miles/features/disguise/entry/cover_entry_trigger.dart';
import 'package:miles/features/disguise/entry/entry_trigger_layer.dart';

/// The layer is the door and it never says a word, so every way it can open
/// and every way it must stay shut is driven through it here with real
/// pointers on the binding's fake clock.
void main() {
  // 360 x 800 logical, no padding: the safe box IS the view, short side 360.
  const view = Size(1080, 2400);
  const box = Size(360, 800);
  Offset px(double x, double y) => Offset(x * 360, y * 360);

  late List<EntrySource> opened;
  late CoverEntryController controller;

  Future<void> pumpLayer(
    WidgetTester tester, {
    CoverEntryTrigger? trigger,
    EntryLayerMode mode = EntryLayerMode.watch,
    Widget? child,
  }) async {
    tester.view.physicalSize = view;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    opened = [];
    controller = CoverEntryController(mode: mode, onOpen: opened.add)
      ..trigger = trigger;
    await tester.pumpWidget(
      MaterialApp(
        home: CoverEntryScope(
          controller: controller,
          child: EntryTriggerLayer(
            controller: controller,
            nowMs: () => tester.binding.clock.now().millisecondsSinceEpoch,
            child: child ??
                const ColoredBox(color: Color(0xFFFFFFFF), child: SizedBox.expand()),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> tap(WidgetTester tester, Offset at, {int gapMs = 300}) async {
    final g = await tester.startGesture(at);
    await tester.pump(const Duration(milliseconds: 80));
    await g.up();
    await tester.pump(Duration(milliseconds: gapMs));
  }

  Future<void> hold(WidgetTester tester, Offset at, int ms) async {
    final g = await tester.startGesture(at);
    await tester.pump(Duration(milliseconds: ms));
    await g.up();
    await tester.pump();
  }

  TouchTrigger sequence() => const TouchTrigger(
        cover: DisguiseCover.news,
        box: box,
        steps: [
          TouchStep(x: 0.3, y: 0.5, holdMs: 0),
          TouchStep(x: 0.7, y: 0.8, holdMs: 0),
          TouchStep(x: 0.5, y: 0.3, holdMs: 2000),
        ],
        radius: [0.1, 0.1, 0.1],
        windowMs: 6000,
        gapMs: 1500,
      );

  TouchTrigger loneHold() => const TouchTrigger(
        cover: DisguiseCover.news,
        box: box,
        steps: [TouchStep(x: 0.5, y: 0.5, holdMs: 3000)],
        radius: [0.1],
        windowMs: 4000,
        gapMs: 1000,
      );

  group('the recorded move', () {
    testWidgets('two taps then a hold, at the spots, opens before the finger '
        'lifts', (tester) async {
      await pumpLayer(tester, trigger: sequence());
      await tap(tester, px(0.31, 0.49));
      await tap(tester, px(0.69, 0.81));
      final g = await tester.startGesture(px(0.5, 0.3));
      await tester.pump(const Duration(milliseconds: 1250));
      expect(opened, [EntrySource.custom],
          reason: '0.6 x 2000ms armed while the finger is still down',);
      await g.up();
      await tester.pump();
      expect(opened.length, 1, reason: 'the up after a fire is not a step');
    });

    testWidgets('the same rhythm elsewhere opens nothing', (tester) async {
      await pumpLayer(tester, trigger: sequence());
      await tap(tester, px(0.31, 0.49));
      await tap(tester, px(0.69, 0.81));
      await hold(tester, px(0.9, 0.3), 2500);
      expect(opened, isEmpty);
    });

    testWidgets('lifting before the hold is long enough opens nothing',
        (tester) async {
      await pumpLayer(tester, trigger: sequence());
      await tap(tester, px(0.31, 0.49));
      await tap(tester, px(0.69, 0.81));
      await hold(tester, px(0.5, 0.3), 700);
      expect(opened, isEmpty);
    });

    testWidgets('a scroll in the middle resets the sequence', (tester) async {
      await pumpLayer(tester, trigger: sequence());
      await tap(tester, px(0.31, 0.49));
      final drag = await tester.startGesture(px(0.5, 0.6));
      await drag.moveBy(const Offset(0, -120));
      await drag.up();
      await tester.pump(const Duration(milliseconds: 200));
      await tap(tester, px(0.69, 0.81));
      await hold(tester, px(0.5, 0.3), 2500);
      expect(opened, isEmpty);
    });

    testWidgets('a background in the middle resets the sequence',
        (tester) async {
      await pumpLayer(tester, trigger: sequence());
      await tap(tester, px(0.31, 0.49));
      await tap(tester, px(0.69, 0.81));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await hold(tester, px(0.5, 0.3), 2500);
      expect(opened, isEmpty);
    });

    testWidgets('a lone hold arms at the record-time floor, not sooner',
        (tester) async {
      // A two-second press is the reflex a curious person uses to look for a
      // menu; the recorder refuses to record one, so matching must refuse to
      // fire on one.
      await pumpLayer(tester, trigger: loneHold());
      final g = await tester.startGesture(px(0.5, 0.5), pointer: 14);
      await tester.pump(const Duration(milliseconds: 2100));
      expect(opened, isEmpty, reason: 'fired inside the reflex band');
      await tester.pump(const Duration(milliseconds: 1000));
      expect(opened, [EntrySource.custom]);
      await g.up();
    });

    testWidgets('a hold that wanders is not a hold', (tester) async {
      await pumpLayer(tester, trigger: loneHold());
      final g = await tester.startGesture(px(0.5, 0.5));
      await tester.pump(const Duration(milliseconds: 500));
      await g.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 2500));
      expect(opened, isEmpty);
      await g.up();
    });

    testWidgets('a touch that starts in the edge band does not count',
        (tester) async {
      await pumpLayer(tester, trigger: loneHold());
      // The recorded spot is 180,180 — recording there is impossible, but a
      // record could be edited; what matters is that the band is dead.
      final g = await tester.startGesture(const Offset(10, 180));
      await tester.pump(const Duration(milliseconds: 2500));
      expect(opened, isEmpty);
      await g.up();
    });

    testWidgets('a move recorded in another box shape is never compared',
        (tester) async {
      await pumpLayer(
        tester,
        trigger: const TouchTrigger(
          cover: DisguiseCover.news,
          box: Size(800, 360),
          steps: [TouchStep(x: 0.5, y: 0.5, holdMs: 3000)],
          radius: [0.1],
          windowMs: 4000,
          gapMs: 1000,
        ),
      );
      await hold(tester, px(0.5, 0.5), 2500);
      expect(opened, isEmpty);
    });

    testWidgets('a tap-ending move cancels the tap under the last finger',
        (tester) async {
      // The up that completes the move is still on its way to the cover's
      // recognisers when the layer sees it; without a cancel routed ahead of
      // it, the button under the last finger fires — an article opening the
      // browser, the Notes + opening the editor over the reveal.
      var pressed = 0;
      await pumpLayer(
        tester,
        trigger: const TouchTrigger(
          cover: DisguiseCover.news,
          box: box,
          steps: [
            TouchStep(x: 0.3, y: 0.5, holdMs: 0),
            TouchStep(x: 0.5, y: 1.5, holdMs: 0),
          ],
          radius: [0.1, 0.1],
          windowMs: 6000,
          gapMs: 1500,
        ),
        child: Stack(
          children: [
            const ColoredBox(
                color: Color(0xFFFFFFFF), child: SizedBox.expand(),),
            Positioned(
              left: 130,
              top: 490,
              child: SizedBox(
                width: 100,
                height: 100,
                child: TextButton(
                  onPressed: () => pressed++,
                  child: const Text('open'),
                ),
              ),
            ),
          ],
        ),
      );
      await tap(tester, px(0.3, 0.5));
      // The last tap lands on the button; the move completes on its up.
      await tap(tester, px(0.5, 1.5));
      expect(opened, [EntrySource.custom]);
      expect(pressed, 0, reason: 'the control under the last tap fired');
      // And a tap that is not a step still reaches the button.
      await tap(tester, px(0.5, 1.5));
      expect(pressed, 1);
    });

    testWidgets('the cover underneath keeps scrolling', (tester) async {
      await pumpLayer(
        tester,
        trigger: sequence(),
        child: ListView(
          children: [
            for (var i = 0; i < 40; i++) SizedBox(height: 60, child: Text('row $i')),
          ],
        ),
      );
      expect(find.text('row 30'), findsNothing);
      await tester.drag(find.text('row 5'), const Offset(0, -1500));
      await tester.pump();
      expect(find.text('row 30'), findsOneWidget);
      expect(opened, isEmpty);
    });
  });

  group('the backup hold', () {
    testWidgets('two still fingers for the full hold open it', (tester) async {
      await pumpLayer(tester);
      final a = await tester.startGesture(px(0.3, 0.5), pointer: 11);
      final b = await tester.startGesture(px(0.7, 0.5), pointer: 12);
      await tester.pump(kCoverRecoveryHold - const Duration(milliseconds: 100));
      expect(opened, isEmpty);
      await tester.pump(const Duration(milliseconds: 200));
      expect(opened, [EntrySource.backup]);
      await a.up();
      await b.up();
    });

    testWidgets('one finger, three seconds, or a drift is not it',
        (tester) async {
      await pumpLayer(tester);
      final one = await tester.startGesture(px(0.3, 0.5));
      await tester.pump(kCoverRecoveryHold + const Duration(seconds: 1));
      await one.up();
      expect(opened, isEmpty, reason: 'one finger');

      final a = await tester.startGesture(px(0.3, 0.5), pointer: 11);
      final b = await tester.startGesture(px(0.7, 0.5), pointer: 12);
      await tester.pump(const Duration(seconds: 3));
      await a.up();
      await b.up();
      await tester.pump();
      expect(opened, isEmpty, reason: 'three seconds');

      final c = await tester.startGesture(px(0.3, 0.5), pointer: 11);
      final d = await tester.startGesture(px(0.7, 0.5), pointer: 12);
      await tester.pump(const Duration(seconds: 1));
      // Derived, never a literal: this was `Offset(40, 0)`, comfortably past
      // the old 24px slop and exactly ON the new one, where `>` is false. A
      // hardcoded distance silently stops testing cancellation the moment the
      // tolerance moves.
      await d.moveBy(const Offset(kBackupSlop + 10, 0));
      await tester.pump(kCoverRecoveryHold);
      await c.up();
      await d.up();
      expect(opened, isEmpty, reason: 'a drift past the tolerance');
    });

    testWidgets('a tremor inside the tolerance still opens it', (tester) async {
      // The point of deriving kBackupSlop from the duration. A resting hand
      // wanders, and over a ten-second hold it wanders further than over five;
      // if this fails the gesture is unusable in the hand even though every
      // other test passes on a machine that never shakes.
      await pumpLayer(tester);
      final a = await tester.startGesture(px(0.3, 0.5), pointer: 21);
      final b = await tester.startGesture(px(0.7, 0.5), pointer: 22);
      const wobble = kBackupSlop / 2;
      for (var i = 0; i < 5; i++) {
        await tester.pump(kCoverRecoveryHold ~/ 6);
        await a.moveBy(Offset(i.isEven ? wobble : -wobble, 0));
        await b.moveBy(Offset(0, i.isEven ? -wobble : wobble));
      }
      await tester.pump(kCoverRecoveryHold);
      expect(opened, [EntrySource.backup],
          reason: 'a hand that wanders within the tolerance must still get in',);
      await a.up();
      await b.up();
    });

    testWidgets('a third finger cancels it', (tester) async {
      await pumpLayer(tester);
      final a = await tester.startGesture(px(0.3, 0.5), pointer: 11);
      final b = await tester.startGesture(px(0.7, 0.5), pointer: 12);
      await tester.pump(const Duration(seconds: 1));
      final c = await tester.startGesture(px(0.5, 0.8), pointer: 13);
      await tester.pump(kCoverRecoveryHold);
      expect(opened, isEmpty);
      await a.up();
      await b.up();
      await c.up();
    });

    testWidgets('it is not live while recording', (tester) async {
      await pumpLayer(tester, mode: EntryLayerMode.record);
      final a = await tester.startGesture(px(0.3, 0.5), pointer: 11);
      final b = await tester.startGesture(px(0.7, 0.5), pointer: 12);
      await tester.pump(kCoverRecoveryHold + const Duration(seconds: 1));
      expect(opened, isEmpty);
      await a.up();
      await b.up();
    });

    testWidgets('a second finger ends a move in progress', (tester) async {
      await pumpLayer(tester, trigger: loneHold());
      final a = await tester.startGesture(px(0.5, 0.5), pointer: 11);
      await tester.pump(const Duration(milliseconds: 500));
      final b = await tester.startGesture(px(0.7, 0.5), pointer: 12);
      await tester.pump(const Duration(seconds: 2));
      expect(opened, isEmpty);
      await a.up();
      await b.up();
    });
  });

  group('recording', () {
    testWidgets('every counted touch is reported with its length',
        (tester) async {
      final seen = <TouchEvent>[];
      await pumpLayer(tester, mode: EntryLayerMode.record);
      controller.onRecordedTouch = seen.add;
      await tap(tester, px(0.3, 0.5));
      await hold(tester, px(0.6, 0.6), 1500);
      expect(seen.length, 2);
      expect(seen[0].isTap, isTrue);
      expect(seen[0].x, closeTo(0.3, 0.01));
      expect(seen[1].durMs, 1500);
      expect(seen[1].y, closeTo(0.6, 0.01));
      expect(opened, isEmpty);
    });

    testWidgets('a drag is not reported', (tester) async {
      final seen = <TouchEvent>[];
      await pumpLayer(tester, mode: EntryLayerMode.record);
      controller.onRecordedTouch = seen.add;
      final g = await tester.startGesture(px(0.3, 0.5));
      await g.moveBy(const Offset(0, 100));
      await g.up();
      await tester.pump();
      expect(seen, isEmpty);
    });
  });

  group('a committed word', () {
    late TextTrigger word;

    setUp(() {
      final (t, err) = TextTrigger.derive('471193', '471193',
          slot: TextSlot.calc, box: box,);
      expect(err, isNull);
      word = t!;
    });

    testWidgets('matches only on commit, and consumes the commit',
        (tester) async {
      await pumpLayer(tester, trigger: word);
      expect(controller.feedText('471193', commit: false), isFalse);
      expect(opened, isEmpty);
      expect(controller.feedText('471194', commit: true), isFalse);
      expect(opened, isEmpty);
      expect(controller.feedText('471193', commit: true), isTrue);
      expect(opened, [EntrySource.custom]);
    });

    testWidgets('is reported while recording, not matched', (tester) async {
      final seen = <String>[];
      await pumpLayer(tester, mode: EntryLayerMode.record);
      controller.onRecordedText = seen.add;
      expect(controller.feedText('lantern', commit: true), isTrue);
      expect(seen, ['lantern']);
      expect(opened, isEmpty);
    });

    test('the stored hash is the app-lock format', () {
      expect(AppLock.secretMatches(word.hash, '471193'), isTrue);
    });
  });
}
