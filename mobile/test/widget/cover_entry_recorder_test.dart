import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/widgets/lock_screen.dart';
import 'package:miles/core/widgets/stealth_overlay.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:miles/features/disguise/entry/cover_entry_recorder_screen.dart';
import 'package:miles/features/disguise/entry/cover_entry_trigger.dart';
import 'package:miles/features/intro/intro_splash_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The recorder is the only loud part of the feature: every refusal and
/// every mismatch says something. What it must never do is run the gate,
/// persist anything, or accept a move the owner cannot repeat.
///
/// Two performances, not three (the owner cut the third on 2026-09-02): the
/// second is where the tolerances come from, so a move that cannot be
/// repeated is still refused.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  CoverEntryTrigger? result;
  var popped = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppLock.availableBiometrics = () async => const [];
    result = null;
    popped = false;
  });

  tearDown(() {
    AppLock.availableBiometrics = AppLock.availableBiometricsLive;
  });

  /// The recorder is pushed as a route, like the picker and the Settings row
  /// push it, so the popped result is observable.
  Future<void> pumpRecorder(WidgetTester tester, DisguiseCover cover) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<CoverEntryTrigger>(
                MaterialPageRoute(
                  builder: (_) => CoverEntryRecorderScreen(
                    cover: cover,
                    nowMs: () =>
                        tester.binding.clock.now().millisecondsSinceEpoch,
                  ),
                ),
              );
              popped = true;
            },
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> hold(WidgetTester tester, Offset at, int ms) async {
    final g = await tester.startGesture(at, pointer: 21);
    await tester.pump(Duration(milliseconds: ms));
    await g.up();
    await tester.pump();
  }

  Future<void> tap(WidgetTester tester, Offset at) async {
    final g = await tester.startGesture(at, pointer: 21);
    await tester.pump(const Duration(milliseconds: 80));
    await g.up();
    await tester.pump(const Duration(milliseconds: 250));
  }

  // Well inside the counted box and well below the card.
  const spot = Offset(180, 450);

  testWidgets('two performances, then done — and the trigger is popped',
      (tester) async {
    await pumpRecorder(tester, DisguiseCover.weather);
    expect(stealthSuppressed.value, isTrue,
        reason: 'the stealth corner must stand down while recording',);
    await tester.tap(find.text('Taps and holds'));
    await tester.pump();
    expect(find.text('Do your move now.'), findsOneWidget);

    await hold(tester, spot, 3200);
    expect(find.text('1 hold'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(find.text('Once more, exactly the same.'), findsOneWidget);

    // The second performance ends it. There is no third.
    await hold(tester, spot, 3400);
    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(find.textContaining("That's it"), findsOneWidget);
    expect(find.textContaining('No hints'), findsNothing,
        reason: 'the rehearsal step is gone',);
    expect(find.byType(LockScreen), findsNothing);
    expect(find.byType(IntroSplashScreen), findsNothing);

    await tester.tap(find.text('Use this move'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(popped, isTrue);
    expect(result, isA<TouchTrigger>());
    final t = result! as TouchTrigger;
    expect(t.cover, DisguiseCover.weather);
    expect(t.steps.single.holdMs, 3200, reason: 'the shorter of the two');
    expect(stealthSuppressed.value, isFalse,
        reason: 'the corner comes back the moment the recorder is gone',);
  });

  testWidgets('the move is drawn as it is made, and only in the recorder',
      (tester) async {
    // The owner asked to see where they are putting the move. A tap and a
    // hold are drawn differently, numbered in order, and the marks are
    // painted above the cover and below the card.
    await pumpRecorder(tester, DisguiseCover.weather);
    expect(find.byType(CustomPaint), findsWidgets);
    await tester.tap(find.text('Taps and holds'));
    await tester.pump();

    await hold(tester, spot, 3200);
    await tester.pump();
    final marks = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .where((p) => p.painter.runtimeType.toString() == '_MarkPainter')
        .toList();
    expect(marks, isNotEmpty, reason: 'the hold must be marked on screen');
    // Never able to swallow a touch: the marks sit under an IgnorePointer.
    expect(
      find.ancestor(
        of: find.byWidget(marks.first),
        matching: find.byType(IgnorePointer),
      ),
      findsWidgets,
    );
    // And they belong to the recorder alone: once it is finished, they stop.
    await tester.tap(find.text('Done'));
    await tester.pump();
    await hold(tester, spot, 3200);
    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(find.textContaining("That's it"), findsOneWidget);
    expect(
      tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .where((p) => p.painter.runtimeType.toString() == '_MarkPainter'),
      isEmpty,
      reason: 'the marks are for setting the move, not for keeping',
    );
  });

  testWidgets('touches made while reading the choice are not a step',
      (tester) async {
    await pumpRecorder(tester, DisguiseCover.weather);
    await tap(tester, spot);
    await tap(tester, spot);
    await tester.tap(find.text('Taps and holds'));
    await tester.pump();
    expect(find.text('Nothing yet'), findsOneWidget);
  });

  testWidgets('while recording taps, the calculator still calculates',
      (tester) async {
    // The move is matched later on a calculator whose = computes; recording
    // it on one whose = is swallowed would record against a different
    // screen. Only a word recording owns the commit.
    await pumpRecorder(tester, DisguiseCover.calculator);
    await tester.tap(find.text('Taps and holds'));
    await tester.pump();
    for (final k in ['7', '+', '2', '=']) {
      await tester.tap(find.widgetWithText(InkWell, k).first);
      await tester.pump();
    }
    expect(find.text('9'), findsWidgets);
  });

  testWidgets('the card can be put out of the way while recording',
      (tester) async {
    // It covers the top of the cover, which is somewhere the owner may want
    // to put their move; hiding it must leave the step and Done reachable.
    await pumpRecorder(tester, DisguiseCover.weather);
    await tester.tap(find.text('Taps and holds'));
    await tester.pump();
    expect(find.textContaining('a hold on its own needs three'), findsOneWidget);
    const card = ValueKey('coverEntryCard');
    final tall = tester.getSize(find.byKey(card)).height;

    await tester.tap(find.text('Hide this'));
    await tester.pump();
    expect(find.textContaining('a hold on its own needs three'), findsNothing,
        reason: 'the instructions are what gets hidden',);
    expect(find.textContaining('Do your move now.'), findsOneWidget,
        reason: 'the step must still be named',);
    expect(find.text('Done'), findsOneWidget);
    expect(tester.getSize(find.byKey(card)).height, lessThan(tall),
        reason: 'hiding it must actually free the screen',);

    // Still records while hidden, and comes back on request.
    await hold(tester, spot, 3200);
    expect(find.textContaining('1 hold'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pump();
    expect(find.textContaining('a hold on its own needs three'), findsOneWidget);
  });

  testWidgets('a touch on the instruction card is not a step of the move',
      (tester) async {
    // The card is a Material, and a Material does not absorb pointers: a tap
    // on its background would fall straight through to the layer and become
    // a phantom mark the owner never meant to make.
    await pumpRecorder(tester, DisguiseCover.weather);
    await tester.tap(find.text('Taps and holds'));
    await tester.pump();
    expect(find.text('Nothing yet'), findsOneWidget);

    final card = tester.getRect(find.byKey(const ValueKey('coverEntryCard')));
    // A point inside the card that is not one of its controls.
    final onCard = Offset(card.left + 8, card.top + 4);
    final g = await tester.startGesture(onCard, pointer: 31);
    await tester.pump(const Duration(milliseconds: 1500));
    await g.up();
    await tester.pump();
    expect(find.text('Nothing yet'), findsOneWidget,
        reason: 'the card swallowed nothing — that hold became a step',);
  });

  testWidgets('a move too easy to hit by accident is refused, out loud',
      (tester) async {
    await pumpRecorder(tester, DisguiseCover.weather);
    await tester.tap(find.text('Taps and holds'));
    await tester.pump();
    await tap(tester, spot);
    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(find.textContaining('One tap is too easy'), findsOneWidget);
    expect(find.text('Do your move now.'), findsOneWidget,
        reason: 'still recording, nothing advanced',);
  });

  testWidgets('a different second recording is refused, out loud',
      (tester) async {
    await pumpRecorder(tester, DisguiseCover.weather);
    await tester.tap(find.text('Taps and holds'));
    await tester.pump();
    await hold(tester, spot, 3200);
    await tester.tap(find.text('Done'));
    await tester.pump();
    await hold(tester, const Offset(300, 700), 3200);
    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(find.textContaining('Not the same spot'), findsOneWidget);
    expect(find.text('Once more, exactly the same.'), findsOneWidget);
  });

  testWidgets('leaving the app mid-attempt refuses the attempt',
      (tester) async {
    await pumpRecorder(tester, DisguiseCover.weather);
    await tester.tap(find.text('Taps and holds'));
    await tester.pump();
    await tap(tester, spot);
    expect(find.text('1 tap'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.textContaining('Interrupted'), findsOneWidget,
        reason: 'an interruption is not the owner doing something wrong',);
    expect(find.text('Nothing yet'), findsOneWidget);
  });

  testWidgets('cancel pops nothing and persists nothing', (tester) async {
    await pumpRecorder(tester, DisguiseCover.weather);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(popped, isTrue);
    expect(result, isNull);
  });

  testWidgets('a cover with a text slot offers the word; one without does not',
      (tester) async {
    await pumpRecorder(tester, DisguiseCover.weather);
    expect(find.text('A secret word'), findsNothing);
    expect(find.text('A secret number'), findsNothing);
  });

  testWidgets('the calculator records a secret number through its own =',
      (tester) async {
    await pumpRecorder(tester, DisguiseCover.calculator);
    await tester.tap(find.text('A secret number'));
    await tester.pump();
    expect(find.text('Type it now.'), findsOneWidget);

    Future<void> type(String digits) async {
      for (final d in digits.split('')) {
        await tester.tap(find.widgetWithText(InkWell, d).first);
        await tester.pump();
      }
      await tester.tap(find.widgetWithText(InkWell, '='));
      await tester.pump();
    }

    await type('123456');
    expect(find.textContaining('straight run'), findsOneWidget);
    await tester.tap(find.text('AC'));
    await tester.pump();
    await type('471193');
    expect(find.text('Once more, exactly the same.'), findsOneWidget);
    await tester.tap(find.text('AC'));
    await tester.pump();
    await type('471193');
    expect(find.textContaining("That's it"), findsOneWidget,
        reason: 'the second entry finishes it — there is no third',);
    expect(find.byType(LockScreen), findsNothing);
  });
}
