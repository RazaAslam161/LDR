import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/widgets/lock_screen.dart';
import 'package:miles/features/disguise/covers/calculator_cover.dart';
import 'package:miles/features/disguise/covers/convert_cover.dart';
import 'package:miles/features/disguise/covers/device_info_cover.dart';
import 'package:miles/features/disguise/covers/level_cover.dart';
import 'package:miles/features/disguise/covers/notes_cover.dart';
import 'package:miles/features/disguise/covers/recorder_cover.dart';
import 'package:miles/features/disguise/covers/timer_cover.dart';
import 'package:miles/features/disguise/covers/weather_cover.dart';
import 'package:miles/features/intro/intro_splash_screen.dart';
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

  /// Nothing a cover does on its own may reach the gate: no lock screen, no
  /// splash, no app name. The covers are pumped without a host, so a door that
  /// somehow survived in one of them would have nowhere to go but here.
  void expectNoDoor(WidgetTester tester, String cover) {
    tester.takeException();
    expect(find.byType(LockScreen), findsNothing,
        reason: '$cover reached the lock on its own',);
    expect(find.byType(IntroSplashScreen), findsNothing,
        reason: '$cover ran the reveal on its own',);
    expect(find.text('Miles'), findsNothing,
        reason: '$cover printed the real name',);
  }

  testWidgets('Convert renders its own identity, not the app theme',
      (tester) async {
    await pumpCover(tester, const ConvertCover());
    expect(find.text('Convert'), findsOneWidget);
    expect(find.text('Length'), findsOneWidget);
    // Metres to feet, computed live as you type.
    await tester.enterText(find.byType(TextField).first, '1');
    await tester.pump();
    expect(find.text('3.2808'), findsOneWidget);
  });

  testWidgets('Timer runs a real stopwatch', (tester) async {
    await pumpCover(tester, const TimerCover());
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

  testWidgets('Level builds without a sensor ever reporting', (tester) async {
    // Emulators and a handful of cheap handsets have no magnetometer, and the
    // accelerometer stream simply never fires in a test. The cover must still
    // be a working screen rather than a blank one.
    await pumpCover(tester, const LevelCover());
    expect(find.text('Level'), findsWidgets);
    expect(find.text('0.0°  ·  0.0°'), findsOneWidget);
  });

  testWidgets('Recorder builds with an empty library', (tester) async {
    // The cover with the most platform surface — recorder, player and a cache
    // directory, none of which exists on a test host. An empty list is the
    // correct outcome; a thrown exception is a black screen on a real phone
    // whose cache directory is unavailable.
    await pumpCover(tester, const RecorderCover());
    await tester.pump();
    expect(find.text('Recorder'), findsOneWidget);
    expect(find.text('00:00'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Device Info builds with no platform channel at all',
      (tester) async {
    // Everything on that screen comes from Android. On a host with none of it,
    // the Dart-side facts still have to render a full screen.
    await pumpCover(tester, const DeviceInfoCover());
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

  group('the doors are gone', () {
    // Every gesture below used to be a way in, or the About sheet that
    // printed the way in. The source scan in disguise_test.dart proves no
    // cover file names the gate; these prove the element the door hung on is
    // now inert on the real widget.
    testWidgets('holding = on a zeroed calculator opens nothing',
        (tester) async {
      await pumpCover(tester, const CalculatorCover());
      await tester.longPress(find.text('='));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('7'));
      await tester.pump();
      expectNoDoor(tester, 'Calculator');
    });

    testWidgets('holding swap on an empty converter opens nothing, and the '
        'title is just a title', (tester) async {
      await pumpCover(tester, const ConvertCover());
      await tester.longPress(find.byIcon(Icons.swap_vert_rounded));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Convert'));
      await tester.pump(const Duration(milliseconds: 400));
      expectNoDoor(tester, 'Convert');
    });

    testWidgets('holding Reset on a resting stopwatch opens nothing',
        (tester) async {
      await pumpCover(tester, const TimerCover());
      await tester.tap(find.text('Stopwatch'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Reset'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Timer').first);
      await tester.pump(const Duration(milliseconds: 400));
      expectNoDoor(tester, 'Timer');
    });

    testWidgets('holding the temperature and tapping the date open nothing',
        (tester) async {
      await pumpCover(tester, const WeatherCover());
      await tester.longPress(find.textContaining('°').first);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Current location'));
      await tester.pump(const Duration(milliseconds: 400));
      expectNoDoor(tester, 'Weather');
    });

    testWidgets('holding the empty-state art on Notes opens nothing',
        (tester) async {
      await pumpCover(tester, const NotesCover());
      await tester.pump();
      await tester.longPress(find.text('Notes you add appear here'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Notes'));
      await tester.pump(const Duration(milliseconds: 400));
      expectNoDoor(tester, 'Notes');
    });

    testWidgets('holding the angle readout on Level opens nothing',
        (tester) async {
      await pumpCover(tester, const LevelCover());
      await tester.longPress(find.text('0.0°  ·  0.0°'));
      await tester.pump(const Duration(milliseconds: 400));
      expectNoDoor(tester, 'Level');
    });

    testWidgets('holding 00:00 on Recorder opens nothing', (tester) async {
      await pumpCover(tester, const RecorderCover());
      await tester.pump();
      await tester.longPress(find.text('00:00'));
      await tester.pump(const Duration(milliseconds: 400));
      expectNoDoor(tester, 'Recorder');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('holding the battery ring on Device Info opens nothing',
        (tester) async {
      await pumpCover(tester, const DeviceInfoCover());
      await tester.pump();
      await tester.longPress(find.text('Device Info'));
      await tester.pump(const Duration(milliseconds: 400));
      expectNoDoor(tester, 'Device Info');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
