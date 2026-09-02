import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/widgets/lock_screen.dart';
import 'package:miles/features/covers/news_cover_screen.dart';
import 'package:miles/features/disguise/cover_gate.dart';
import 'package:miles/features/disguise/disguise_cover_host.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:miles/features/disguise/entry/cover_entry_store.dart';
import 'package:miles/features/disguise/entry/cover_entry_trigger.dart';
import 'package:miles/features/intro/intro_splash_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The cover screen is the first thing a user sees on every cold start. If
/// anything it awaits can hang, the app shows a blank rectangle with no way
/// forward — which is what "re-opens and sticks on this page" looked like.
///
/// These assert on the widget TREE rather than pixels: the covers do real work
/// (RSS, images) that a headless test cannot complete, so layout/network noise
/// is drained with takeException. What matters is that a cover is mounted at
/// all, in every failure mode — and, since the host owns every door now, that
/// each door opens for the right state and stays shut for the rest.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('miles/disguise');

  void mockChannel(Future<Object?> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  late Map<String, String> secure;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secure = {};
    FlutterSecureStorage.setMockInitialValues(secure);
    CoverEntryStore.resetForTest();
    AppLock.locked.value = false;
    // No biometrics enrolled on the test host, answered promptly: the real
    // probe's channel never replies under `flutter test`.
    AppLock.availableBiometrics = () async => const [];
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    AppLock.availableBiometrics = AppLock.availableBiometricsLive;
  });

  var opened = false;

  Future<void> pumpHost(WidgetTester tester) async {
    // A realistic phone surface; the default 800x600 makes the covers overflow.
    // 360 x 800 logical, no padding: the safe box is the view, short side 360.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    opened = false;

    await tester.pumpWidget(
      MaterialApp(home: DisguiseCoverHost(onAuthenticated: () => opened = true)),
    );
  }

  /// A cover is mounted. Drains rendering/network noise the covers produce
  /// headlessly — we are asserting reachability, not paint.
  void expectCoverMounted(WidgetTester tester, {required String when}) {
    tester.takeException();
    expect(find.byType(NewsCoverScreen), findsOneWidget,
        reason: 'no cover mounted $when — the user would be stuck on a blank '
            'screen with no way into the app',);
  }

  /// The covers throw layout and network noise headlessly, more than one
  /// exception a frame once cached articles render at 360dp; a door test is
  /// about the tree, so all of it is drained before an assertion.
  void drain(WidgetTester tester) {
    while (tester.takeException() != null) {}
  }

  /// Two still fingers on the cover for the backup hold's length.
  Future<void> backupHold(WidgetTester tester) async {
    final a = await tester.startGesture(const Offset(100, 400), pointer: 11);
    final b = await tester.startGesture(const Offset(260, 400), pointer: 12);
    await tester.pump(kCoverRecoveryHold + const Duration(milliseconds: 100));
    await a.up();
    await b.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    drain(tester);
  }

  const box = Size(360, 800);

  TouchTrigger loneHold(DisguiseCover cover, {double x = 0.5, double y = 0.5}) =>
      TouchTrigger(
        cover: cover,
        box: box,
        steps: [TouchStep(x: x, y: y, holdMs: 3000)],
        radius: const [0.1],
        windowMs: 4000,
        gapMs: 1000,
      );

  testWidgets('mounts a cover when the platform channel never answers',
      (tester) async {
    // The exact failure that stranded users: an await that never completes.
    mockChannel((_) => Completer<Object?>().future);

    await pumpHost(tester);
    await tester.pump(const Duration(seconds: 5)); // past every timeout

    expectCoverMounted(tester, when: 'when the channel hangs');
  });

  testWidgets('mounts a cover when the channel throws', (tester) async {
    mockChannel((_) async => throw PlatformException(code: 'boom'));

    await pumpHost(tester);
    await tester.pump(const Duration(seconds: 5));

    expectCoverMounted(tester, when: 'when the channel throws');
  });

  testWidgets('mounts a cover on the very first frame', (tester) async {
    mockChannel((_) async => 'News');

    await pumpHost(tester);
    await tester.pump(); // first frame only, before any async resolves

    // The old code rendered a bare ColoredBox here, so a slow disk read
    // surfaced as a blank screen.
    expectCoverMounted(tester, when: 'on the first frame');
  });

  group('the in-cover unread dot', () {
    // Covers post no notification at all (the shade header would say
    // "Miles"), so this dot is the ONLY unread signal a disguised user gets.
    const dot = ValueKey('coverUnreadDot');

    testWidgets('shows when a background push left unread waiting',
        (tester) async {
      mockChannel((_) async => 'News');
      SharedPreferences.setMockInitialValues({
        'active_couple_id': 'c-1',
        'miles_unread_c-1': 3,
      });

      await pumpHost(tester);
      await tester.pump(const Duration(seconds: 5));

      tester.takeException();
      expect(find.byKey(dot), findsOneWidget,
          reason: 'unread behind a cover must surface somewhere, and the '
              'cover UI is the only place the OS cannot relabel',);
    });

    testWidgets('absent when nothing is unread', (tester) async {
      mockChannel((_) async => 'News');
      SharedPreferences.setMockInitialValues({'active_couple_id': 'c-1'});

      await pumpHost(tester);
      await tester.pump(const Duration(seconds: 5));

      tester.takeException();
      expect(find.byKey(dot), findsNothing);
    });

    testWidgets('absent when signed out, even over a stale tally',
        (tester) async {
      // No active_couple_id: the previous account's tally must not put a
      // signal on the next person's cover.
      mockChannel((_) async => 'News');
      SharedPreferences.setMockInitialValues({'miles_unread_c-1': 3});

      await pumpHost(tester);
      await tester.pump(const Duration(seconds: 5));

      tester.takeException();
      expect(find.byKey(dot), findsNothing);
    });
  });

  group('the doors', () {
    // The pinned handsets' first launch after the update: a cover worn,
    // nothing recorded, App Lock off. The backup hold is their door, and it
    // runs the ordinary lock — which, off, means straight to the reveal.
    testWidgets('nothing recorded: the two-finger hold reaches the reveal',
        (tester) async {
      mockChannel((_) async => 'News');
      await pumpHost(tester);
      await tester.pump(const Duration(seconds: 1));

      await backupHold(tester);
      expect(find.byType(IntroSplashScreen), findsOneWidget,
          reason: 'with no move and no lock the backup hold is the way in',);
      expect(find.byType(LockScreen), findsNothing);
    });

    testWidgets('a move that could not be read: the hold lands on a nameless '
        'PIN screen', (tester) async {
      mockChannel((_) async => 'News');
      await AppLock.setPin('1234');
      SharedPreferences.setMockInitialValues({
        CoverEntryStore.mirrorKeyFor(DisguiseCover.news): true,
      });
      secure[CoverEntryStore.keyFor(DisguiseCover.news)] = '{"v":99}';
      await pumpHost(tester);
      await tester.pump(const Duration(seconds: 1));

      await backupHold(tester);
      expect(find.byType(LockScreen), findsOneWidget,
          reason: 'a mirror without a readable record must not reopen a '
              'public door — the backup ends at the PIN',);
      expect(find.text('Locked'), findsOneWidget);
      expect(find.text('Miles is locked'), findsNothing,
          reason: 'the backup lock names no app',);
      expect(find.byType(IntroSplashScreen), findsNothing);
      expect(opened, isFalse);
      await Navigator.of(tester.element(find.byType(LockScreen))).maybePop();
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('a recorded move: the hold lands on the PIN, and the move '
        'itself opens', (tester) async {
      mockChannel((_) async => 'News');
      await AppLock.setPin('1234');
      await CoverEntryStore.save(loneHold(DisguiseCover.news));
      await pumpHost(tester);
      await tester.pump(const Duration(seconds: 1));

      await backupHold(tester);
      expect(find.byType(LockScreen), findsOneWidget);
      expect(find.text('Locked'), findsOneWidget);
      // Back returns to the cover, silently, and leaves no lock behind.
      await Navigator.of(tester.element(find.byType(LockScreen))).maybePop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);
      expect(find.byType(LockScreen), findsNothing);
      expect(AppLock.locked.value, isFalse);

      // The move itself: held for the recorded length, on the recorded spot.
      // App Lock is off, so it goes straight to the reveal — the owner's
      // choice, stated in the picker.
      final g = await tester.startGesture(const Offset(180, 180), pointer: 15);
      await tester.pump(const Duration(milliseconds: 3100));
      await g.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);
      expect(find.byType(IntroSplashScreen), findsOneWidget);
    });

    testWidgets('a recorded move: the wrong spot opens nothing, silently',
        (tester) async {
      mockChannel((_) async => 'News');
      await CoverEntryStore.save(loneHold(DisguiseCover.news));
      await pumpHost(tester);
      await tester.pump(const Duration(seconds: 1));

      final g = await tester.startGesture(const Offset(300, 700));
      await tester.pump(const Duration(milliseconds: 3500));
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);
      expect(find.byType(IntroSplashScreen), findsNothing);
      expect(find.byType(LockScreen), findsNothing);
      expect(find.text('Miles'), findsNothing);
    });

    testWidgets("a move recorded for another cover is not this cover's",
        (tester) async {
      mockChannel((_) async => 'News');
      await CoverEntryStore.save(loneHold(DisguiseCover.calculator));
      await pumpHost(tester);
      await tester.pump(const Duration(seconds: 1));

      final g = await tester.startGesture(const Offset(180, 180));
      await tester.pump(const Duration(milliseconds: 3500));
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);
      expect(find.byType(IntroSplashScreen), findsNothing);
    });

    testWidgets('a fired hold cancels the touch under the finger',
        (tester) async {
      // Notes: the recorded spot is the + button. Without the cancel, the up
      // after the reveal starts would open the note editor over it.
      mockChannel((_) async => 'Notes');
      await CoverEntryStore.save(
        loneHold(DisguiseCover.notes, x: 328 / 360, y: 736 / 360),
      );
      await pumpHost(tester);
      await tester.pump(const Duration(seconds: 1));
      final fab = tester.getCenter(find.byType(FloatingActionButton));

      final g = await tester.startGesture(fab, pointer: 16);
      await tester.pump(const Duration(milliseconds: 3100));
      await g.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);
      expect(find.byType(IntroSplashScreen), findsOneWidget);
      expect(find.text('Save'), findsNothing,
          reason: 'the note editor opened under the reveal',);
    });

    testWidgets('a ring that was not tapped never opens the cover',
        (tester) async {
      // The partner pressing Call must not replace the cover with their face.
      // Only a notification the owner actually tapped is intent.
      mockChannel((_) async => 'News');
      await pumpHost(tester);
      await tester.pump(const Duration(seconds: 1));

      pendingCall.value = const CallTap('x', 'Someone', false, fromTap: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);
      expect(find.byType(IntroSplashScreen), findsNothing,
          reason: 'an untapped ring opened the app',);
      expect(find.byType(LockScreen), findsNothing);
      pendingCall.value = null;
    });

    testWidgets('a stored secret number opens from the cover\'s own = key',
        (tester) async {
      // The one end-to-end proof of the word kind: a record in the store, the
      // real cover, and the key the cover already has.
      mockChannel((_) async => 'Calculator');
      final (t, err) = TextTrigger.derive('471193', '471193',
          slot: TextSlot.calc, box: box,);
      expect(err, isNull);
      await CoverEntryStore.save(t!);
      await pumpHost(tester);
      await tester.pump(const Duration(seconds: 1));
      drain(tester);

      for (final d in '471193'.split('')) {
        await tester.tap(find.widgetWithText(InkWell, d).first);
        await tester.pump();
      }
      expect(find.text('471193'), findsWidgets,
          reason: 'the calculator must behave like a calculator while typing',);
      await tester.tap(find.widgetWithText(InkWell, '='));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);
      expect(find.byType(IntroSplashScreen), findsOneWidget,
          reason: 'the committed secret did not open the cover',);
    });

    testWidgets('a wrong number on the same key opens nothing, silently',
        (tester) async {
      mockChannel((_) async => 'Calculator');
      final (t, _) = TextTrigger.derive('471193', '471193',
          slot: TextSlot.calc, box: box,);
      await CoverEntryStore.save(t!);
      await pumpHost(tester);
      await tester.pump(const Duration(seconds: 1));
      drain(tester);

      for (final d in '471194'.split('')) {
        await tester.tap(find.widgetWithText(InkWell, d).first);
        await tester.pump();
      }
      await tester.tap(find.widgetWithText(InkWell, '='));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);
      expect(find.byType(IntroSplashScreen), findsNothing);
      expect(find.byType(LockScreen), findsNothing);
      expect(find.text('Miles'), findsNothing);
    });

    testWidgets('a note offered as the secret is never written down',
        (tester) async {
      // A near-miss would otherwise pile the owner's half-remembered secret
      // into a plain-prefs list on the cover an attacker is already reading.
      mockChannel((_) async => 'Notes');
      final (t, _) = TextTrigger.derive('lanternfish', 'lanternfish',
          slot: TextSlot.notes, box: box,);
      await CoverEntryStore.save(t!);
      await pumpHost(tester);
      await tester.pump(const Duration(seconds: 1));
      drain(tester);

      // The pad loads its notes from prefs before it draws anything, so the
      // + button is not there on the frame the host mounts.
      for (var i = 0; i < 10 && find.byIcon(Icons.add).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.byIcon(Icons.add), findsOneWidget,
          reason: 'the notepad never finished loading',);

      Future<void> writeNote(String title) async {
        await tester.tap(find.byIcon(Icons.add));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.enterText(find.byType(TextField).first, title);
        await tester.pump();
        await tester.tap(find.text('Save'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        drain(tester);
      }

      // A near miss: offered, refused, and not kept.
      await writeNote('lanternfis');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('notes_cover_items') ?? const [], isEmpty,
          reason: 'a title offered as the secret was written to disk',);
      expect(find.byType(IntroSplashScreen), findsNothing);

      // And the real one opens.
      await writeNote('lanternfish');
      expect(find.byType(IntroSplashScreen), findsOneWidget);
      expect(prefs.getStringList('notes_cover_items') ?? const [], isEmpty);
    });

    testWidgets('under a screen reader the Unlock node reaches the PIN',
        (tester) async {
      mockChannel((_) async => 'News');
      await AppLock.setPin('1234');
      await CoverEntryStore.save(loneHold(DisguiseCover.news));
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(accessibleNavigation: true),
            child: child!,
          ),
          home: DisguiseCoverHost(onAuthenticated: () {}),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      await tester.tap(find.bySemanticsLabel('Unlock'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);
      expect(find.byType(LockScreen), findsOneWidget);
      expect(find.text('Locked'), findsOneWidget);
    });
  });
}
