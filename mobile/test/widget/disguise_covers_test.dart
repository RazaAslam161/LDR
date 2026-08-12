import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/disguise/covers/convert_cover.dart';
import 'package:miles/features/disguise/covers/device_info_cover.dart';
import 'package:miles/features/disguise/covers/level_cover.dart';
import 'package:miles/features/disguise/covers/recorder_cover.dart';
import 'package:miles/features/disguise/covers/timer_cover.dart';
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
}
