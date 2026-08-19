import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/disguise/cover_gate.dart';
import 'package:miles/features/disguise/covers/convert_cover.dart';
import 'package:miles/features/disguise/covers/device_info_cover.dart';
import 'package:miles/features/disguise/covers/level_cover.dart';
import 'package:miles/features/disguise/covers/recorder_cover.dart';
import 'package:miles/features/disguise/covers/timer_cover.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A cover that throws while building is not a bug with a stack trace — it is a
/// black screen where a stock utility should be, on the one screen the whole
/// threat model rests on. None of these covers is on a route a widget test
/// would otherwise reach, so this is the only thing that ever builds them.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpCover(WidgetTester tester, Widget cover) async {
    await tester.pumpWidget(MaterialApp(home: cover));
    await tester.pump();
  }

  testWidgets('Convert renders its own identity, not the app theme',
      (tester) async {
    await pumpCover(tester, ConvertCover(onAuthenticated: () {}));
    expect(find.text('Convert'), findsOneWidget);
    expect(find.text('Length'), findsOneWidget);
    // Metres to feet, computed live as you type.
    await tester.enterText(find.byType(TextField).first, '1');
    await tester.pump();
    expect(find.text('3.2808'), findsOneWidget);
  });

  testWidgets('holding swap on two different units does nothing',
      (tester) async {
    // The negative half of the door, and the one that matters: the gate must
    // stay shut for anyone using the converter normally. If this ever opens it
    // reaches the app lock, and the test fails on the missing plugin rather
    // than passing quietly.
    var opened = false;
    await pumpCover(tester, ConvertCover(onAuthenticated: () => opened = true));
    await tester.longPress(find.byIcon(Icons.swap_vert_rounded));
    await tester.pump();
    expect(opened, isFalse);
  });

  testWidgets('Timer runs a real stopwatch', (tester) async {
    await pumpCover(tester, TimerCover(onAuthenticated: () {}));
    expect(find.text('05:00'), findsOneWidget); // the default countdown

    await tester.tap(find.text('Stopwatch'));
    await tester.pumpAndSettle();
    expect(find.text('00:00.00'), findsOneWidget);

    // A running stopwatch offers Lap and Stop; a stopped one offers Reset and
    // Start. The digits themselves are wall-clock and do not move under a test
    // binding's fake time, so the state is what is worth asserting here.
    await tester.tap(find.text('Start'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Lap'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);

    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(find.text('Reset'), findsOneWidget);
  });

  testWidgets('holding Lap on a running stopwatch does nothing',
      (tester) async {
    var opened = false;
    await pumpCover(tester, TimerCover(onAuthenticated: () => opened = true));
    await tester.tap(find.text('Stopwatch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start'));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.longPress(find.text('Lap'));
    await tester.pump();
    expect(opened, isFalse);

    await tester.tap(find.text('Stop'));
    await tester.pump();
  });

  testWidgets('Level builds without a sensor ever reporting', (tester) async {
    // Emulators and a handful of cheap handsets have no magnetometer, and the
    // accelerometer stream simply never fires in a test. The cover must still
    // be a working screen rather than a blank one.
    await pumpCover(tester, LevelCover(onAuthenticated: () {}));
    expect(find.text('Level'), findsWidgets);
    expect(find.text('0.0°  ·  0.0°'), findsOneWidget);
  });

  testWidgets('Recorder builds with an empty library', (tester) async {
    // The cover with the most platform surface — recorder, player and a cache
    // directory, none of which exists on a test host. An empty list is the
    // correct outcome; a thrown exception is a black screen on a real phone
    // whose cache directory is unavailable.
    await pumpCover(tester, RecorderCover(onAuthenticated: () {}));
    await tester.pump();
    expect(find.text('Recorder'), findsOneWidget);
    expect(find.text('00:00'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Device Info builds with no platform channel at all',
      (tester) async {
    // Everything on that screen comes from Android. On a host with none of it,
    // the Dart-side facts still have to render a full screen.
    await pumpCover(tester, DeviceInfoCover(onAuthenticated: () {}));
    await tester.pump();
    expect(find.text('Device Info'), findsOneWidget);
    expect(find.text('Storage'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('CPU cores'), 250);
    expect(find.text('CPU cores'), findsOneWidget);

    // Tear the cover down and let the in-flight platform call time out. That
    // nothing is left pending is the assertion: this screen polls, and a timer
    // or a hung channel call surviving dispose is a leak on the one widget
    // that is built on every single cold start.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  });

  group('the About panel', () {
    // The source scan in disguise_test.dart proves every cover CALLS
    // showCoverAbout. It cannot prove the call is reachable: a handler on a
    // widget that never renders, or on one the user cannot hit, satisfies it
    // exactly. These pump the real cover and tap the real element, which is
    // the property the change actually claims — an element the cover already
    // draws opens the panel.
    // Fixed pumps, not pumpAndSettle: Device Info runs a 3s refresh timer, so
    // nothing on that cover ever settles. 400ms clears the sheet's animation.
    Future<void> tapAbout(WidgetTester tester, Finder target) async {
      await tester.tap(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('Convert opens it from the title, and it names Miles and '
        "Convert's own gesture", (tester) async {
      var opened = false;
      await pumpCover(tester, ConvertCover(onAuthenticated: () => opened = true));
      await tapAbout(tester, find.text('Convert'));

      expect(find.text('Miles'), findsOneWidget);
      expect(find.text(profileForCover(DisguiseCover.convert).entry),
          findsOneWidget,);
      // Not another cover's instructions — the bug the apply dialog shipped.
      expect(find.text(profileForCover(DisguiseCover.news).entry), findsNothing);
      // Reading the way back is not walking through it.
      expect(opened, isFalse);
    });

    testWidgets('Timer opens it from the title', (tester) async {
      await pumpCover(tester, TimerCover(onAuthenticated: () {}));
      await tapAbout(tester, find.text('Timer').first);
      expect(find.text(profileForCover(DisguiseCover.timer).entry),
          findsOneWidget,);
    });

    testWidgets('Device Info opens it from the title', (tester) async {
      await pumpCover(tester, DeviceInfoCover(onAuthenticated: () {}));
      await tapAbout(tester, find.text('Device Info'));
      expect(find.text(profileForCover(DisguiseCover.device).entry),
          findsOneWidget,);
      // Same teardown as the sibling build test: this cover polls every 3s, so
      // the in-flight platform call has to be let go before the binding checks
      // for pending timers.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('the Recorder panel stays dark, like the cover behind it',
        (tester) async {
      // The four covers that hand-roll a palette pass it in; the five that
      // build a coverTheme pass that. Recorder is the only dark one, so it is
      // the only call site where losing `brightness` would be visible — a
      // white sheet over a black recorder is the tell cover_theme.dart exists
      // to prevent.
      await pumpCover(tester, RecorderCover(onAuthenticated: () {}));
      await tapAbout(tester, find.text('Recorder'));

      final sheetTheme = Theme.of(
        tester.element(find.text(profileForCover(DisguiseCover.recorder).entry)),
      );
      expect(sheetTheme.brightness, Brightness.dark);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Open Miles runs the entry flow; dismissing it does not',
        (tester) async {
      // The panel is a leaflet unless its button reaches the gate. With no
      // App Lock enrolled the gate passes straight through to
      // onCoverUnlocked, which is what onAuthenticated observes.
      var opened = false;
      await pumpCover(tester, ConvertCover(onAuthenticated: () => opened = true));
      await tapAbout(tester, find.text('Convert'));
      expect(opened, isFalse);

      await tester.tap(find.text('Open Miles'));
      await tester.pumpAndSettle();
      expect(opened, isTrue);
    });

    testWidgets('the Open button survives a large font scale', (tester) async {
      // It is the last thing in the column and the column is as tall as the
      // gesture text makes it, so at the default sheet cap it clipped off the
      // bottom — the recovery control, gone for the users likeliest to need
      // it. Convert has the longest gesture string of the nine.
      tester.view.physicalSize = const Size(1080, 2280);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: ConvertCover(onAuthenticated: () {}),
        ),
      ),);
      await tester.pump();
      await tapAbout(tester, find.text('Convert'));

      final button = find.text('Open Miles');
      expect(button, findsOneWidget);
      expect(tester.getRect(button).bottom,
          lessThanOrEqualTo(tester.view.physicalSize.height /
              tester.view.devicePixelRatio,),
          reason: 'the Open button is off the bottom of the screen',);
    });

    testWidgets('the door is a 48dp target, not a line of text',
        (tester) async {
      // 20dp of glyph box is thin for the one control someone locked out of
      // their own app has to find a month later. The AppBar toolbar is 56dp,
      // so the height is free.
      await pumpCover(tester, ConvertCover(onAuthenticated: () {}));
      expect(tester.getSize(find.byType(CoverAboutTap)).height, 48);
    });
  });

}
